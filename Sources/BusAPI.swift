import Foundation

/// 국토교통부(TAGO) 버스정류소정보 · 버스도착정보 API
struct BusStop: Identifiable, Hashable {
    let id: String
    let name: String
    let number: String

    var label: String { number.isEmpty ? name : "\(name) (\(number))" }
}

struct BusArrival: Identifiable {
    var id: String { "\(routeNo)-\(seconds)" }
    let routeNo: String
    /// 조회 시점 기준 도착까지 남은 초
    let seconds: Int
    let stopsAway: Int
    let vehicleType: String
}

extension RailAPI {
    private static let busCityCache = "busCityCodes"

    /// 주소(예: "울산광역시 북구 …")로 TAGO 도시코드를 찾는다.
    func busCityCode(forAddress address: String) async throws -> String {
        let defaults = UserDefaults.standard
        var cities = defaults.dictionary(forKey: Self.busCityCache) as? [String: String] ?? [:]
        if cities.isEmpty {
            for item in try await request("BusSttnInfoInqireService/getCtyCodeList", [:]) {
                let code = Self.string(item["citycode"])
                let name = Self.string(item["cityname"])
                if !code.isEmpty && !name.isEmpty { cities[name] = code }
            }
            guard !cities.isEmpty else { throw RailAPIError.empty("버스 도시 목록") }
            defaults.set(cities, forKey: Self.busCityCache)
        }

        let tokens = address.split(separator: " ").prefix(3).map(String.init)
        for token in tokens {
            if let code = cities[token] { return code }
        }
        for token in tokens where token.count >= 2 {
            let short = String(token.prefix(2))
            if let match = cities.first(where: { $0.key.hasPrefix(short) }) { return match.value }
        }
        throw RailAPIError.noStation(address)
    }

    func busStops(cityCode: String, named name: String) async throws -> [BusStop] {
        try await request("BusSttnInfoInqireService/getSttnNoList", [
            "cityCode": cityCode,
            "nodeNm": name,
            "numOfRows": "50",
            "pageNo": "1"
        ]).compactMap { item in
            let id = Self.string(item["nodeid"])
            guard !id.isEmpty else { return nil }
            return BusStop(id: id, name: Self.string(item["nodenm"]), number: Self.string(item["nodeno"]))
        }
    }

    func busArrivals(cityCode: String, stopId: String) async throws -> [BusArrival] {
        try await request("ArvlInfoInqireService/getSttnAcctoArvlPrearngeInfoList", [
            "cityCode": cityCode,
            "nodeId": stopId,
            "numOfRows": "100",
            "pageNo": "1"
        ]).compactMap { item in
            let routeNo = Self.string(item["routeno"])
            guard !routeNo.isEmpty, let seconds = Int(Self.string(item["arrtime"])) else { return nil }
            return BusArrival(
                routeNo: routeNo,
                seconds: seconds,
                stopsAway: Int(Self.string(item["arrprevstationcnt"])) ?? 0,
                vehicleType: Self.string(item["vehicletp"])
            )
        }
        .sorted { $0.seconds < $1.seconds }
    }
}

/// 어느 정류장의 버스를 볼지
enum BusKind {
    /// 타는 역까지 가는 버스 (예: 명촌차고지 → 태화강역)
    case origin
    /// 내린 역에서 갈아탈 버스 (예: 태화강역 → 명촌공영차고지)
    case connect
}

extension Route {
    func busStopName(_ kind: BusKind) -> String {
        kind == .origin ? busOrigin : connectStopName
    }

    func busAddress(_ kind: BusKind) -> String {
        let address = kind == .origin ? busOriginAddress : connectAddress
        return address.isEmpty ? busStopName(kind) : address
    }

    func busRouteNumbers(_ kind: BusKind) -> [String] {
        kind == .origin ? busRoutes : connectRoutes
    }

    func savedBusStopId(_ kind: BusKind) -> String {
        kind == .origin ? busStopId : connectStopId
    }

    mutating func setBusStop(_ stop: BusStop, kind: BusKind) {
        switch kind {
        case .origin:
            busStopId = stop.id
            busStopLabel = stop.label
        case .connect:
            connectStopId = stop.id
            connectStopLabel = stop.label
        }
    }

    func hasBus(_ kind: BusKind) -> Bool {
        !busStopName(kind).isEmpty && !busRouteNumbers(kind).isEmpty
    }
}

/// 노선별 실시간 버스 도착정보. 화면이 떠 있는 동안 주기적으로 새로 받는다.
@MainActor
final class BusStore: ObservableObject {
    struct State {
        var cityCode = ""
        var candidates: [BusStop] = []
        var stop: BusStop?
        var arrivals: [BusArrival] = []
        var fetchedAt: Date?
        var error: String?
    }

    /// 버스로 갈아탈 수 있는 경우
    struct Connection {
        let arrival: BusArrival
        /// 버스가 정류장에 오는 시각
        let busTime: Date
        /// 열차에서 내려 정류장에 도착한 뒤 기다리는 시간(초)
        let wait: Int
    }

    @Published private(set) var states: [String: State] = [:]
    private var loading: Set<String> = []

    private func key(_ route: Route, _ kind: BusKind) -> String {
        "\(route.id.uuidString)-\(kind == .origin ? "origin" : "connect")"
    }

    func state(for route: Route, kind: BusKind = .origin) -> State? { states[key(route, kind)] }

    /// 이 노선의 버스만, 지금 시각 기준 남은 초로 다시 계산해서 돌려준다.
    func upcoming(for route: Route, kind: BusKind = .origin, now: Date = Date()) -> [(arrival: BusArrival, remaining: Int)] {
        guard let state = states[key(route, kind)], let fetchedAt = state.fetchedAt else { return [] }
        let elapsed = Int(now.timeIntervalSince(fetchedAt))
        let wanted = Set(route.busRouteNumbers(kind))
        return state.arrivals
            .filter { wanted.isEmpty || wanted.contains($0.routeNo) }
            .map { (arrival: $0, remaining: $0.seconds - elapsed) }
            .filter { $0.remaining > -60 }
    }

    /// 열차가 도착하고 환승 이동 시간이 지난 뒤 탈 수 있는 버스
    func connections(for route: Route, trainArrival: Date, now: Date = Date()) -> [Connection] {
        let ready = trainArrival.addingTimeInterval(Double(route.connectTransferMinutes * 60))
        return upcoming(for: route, kind: .connect, now: now).compactMap { item in
            let busTime = now.addingTimeInterval(Double(item.remaining))
            let wait = Int(busTime.timeIntervalSince(ready))
            return wait >= 0 ? Connection(arrival: item.arrival, busTime: busTime, wait: wait) : nil
        }
    }

    /// 잠금화면·카드용 한 줄 요약
    /// - 갈아탈 버스가 있는 노선: "🚌 태화강역 717번 07:02 (대기 4분)"
    /// - 그 외: "🚌 717번 3분 후"
    func summary(for route: Route, now: Date = Date()) -> String? {
        if route.hasBus(.connect) {
            let day = DayOverride.effective(raw: SharedData.dayOverrideRaw, on: now)
            guard let arrival = route.activityTrains(from: now, day: day, limit: 1).first?.arrival,
                  let next = connections(for: route, trainArrival: arrival, now: now).first else { return nil }
            return "🚌 \(route.connectStopName) \(next.arrival.routeNo)번 \(TimeText.clock(next.busTime)) (대기 \(next.wait / 60)분)"
        }
        guard let next = upcoming(for: route, now: now).first else { return nil }
        let time = next.remaining < 60 ? "곧 도착" : "\(next.remaining / 60)분 후"
        return "🚌 \(next.arrival.routeNo)번 \(time)"
    }

    /// 노선에 등록된 버스 정류장(출발·환승)을 모두 갱신
    func refreshAll(route: Route, key apiKey: String, store: RouteStore, minInterval: TimeInterval) async {
        for kind in [BusKind.origin, .connect] where route.hasBus(kind) {
            await refresh(route: route, kind: kind, key: apiKey, store: store, minInterval: minInterval)
        }
    }

    func refresh(route: Route, kind: BusKind = .origin, key apiKey: String, store: RouteStore, minInterval: TimeInterval = 45) async {
        guard route.hasBus(kind), let api = try? RailAPI(serviceKey: apiKey) else { return }
        let stateKey = key(route, kind)
        if let fetched = states[stateKey]?.fetchedAt, Date().timeIntervalSince(fetched) < minInterval { return }
        if loading.contains(stateKey) { return }
        loading.insert(stateKey)
        defer { loading.remove(stateKey) }

        var state = states[stateKey] ?? State()
        do {
            if state.cityCode.isEmpty {
                state.cityCode = try await api.busCityCode(forAddress: route.busAddress(kind))
            }
            if state.candidates.isEmpty {
                state.candidates = try await api.busStops(cityCode: state.cityCode, named: route.busStopName(kind))
                guard !state.candidates.isEmpty else { throw RailAPIError.noStation(route.busStopName(kind)) }
            }

            if let saved = state.candidates.first(where: { $0.id == route.savedBusStopId(kind) }) {
                state.stop = saved
                state.arrivals = try await api.busArrivals(cityCode: state.cityCode, stopId: saved.id)
            } else {
                // 같은 이름 정류장이 여러 개면(방향별) 등록한 버스가 가장 많이 오는 곳을 고른다.
                let wanted = Set(route.busRouteNumbers(kind))
                var best: (stop: BusStop, arrivals: [BusArrival], score: Int)?
                for stop in state.candidates.prefix(6) {
                    let arrivals = try await api.busArrivals(cityCode: state.cityCode, stopId: stop.id)
                    let score = Set(arrivals.map(\.routeNo)).intersection(wanted).count
                    if best == nil || score > best!.score { best = (stop, arrivals, score) }
                }
                if let best {
                    state.stop = best.stop
                    state.arrivals = best.arrivals
                    if best.score > 0, var updated = store.route(id: route.id) {
                        updated.setBusStop(best.stop, kind: kind)
                        store.upsert(updated)
                    }
                }
            }
            state.fetchedAt = Date()
            state.error = nil
        } catch {
            state.error = error.localizedDescription
            state.fetchedAt = Date()
        }
        states[stateKey] = state
    }

    func choose(_ stop: BusStop, for route: Route, kind: BusKind = .origin, store: RouteStore) {
        if var updated = store.route(id: route.id) {
            updated.setBusStop(stop, kind: kind)
            store.upsert(updated)
        }
        states[key(route, kind)]?.fetchedAt = nil
    }
}
