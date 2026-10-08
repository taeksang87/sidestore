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

    @Published private(set) var states: [UUID: State] = [:]
    private var loading: Set<UUID> = []

    func state(for route: Route) -> State? { states[route.id] }

    /// 이 노선의 경유버스만, 지금 시각 기준 남은 초로 다시 계산해서 돌려준다.
    func upcoming(for route: Route, now: Date = Date()) -> [(arrival: BusArrival, remaining: Int)] {
        guard let state = states[route.id], let fetchedAt = state.fetchedAt else { return [] }
        let elapsed = Int(now.timeIntervalSince(fetchedAt))
        let wanted = Set(route.busRoutes)
        return state.arrivals
            .filter { wanted.isEmpty || wanted.contains($0.routeNo) }
            .map { (arrival: $0, remaining: $0.seconds - elapsed) }
            .filter { $0.remaining > -60 }
    }

    /// "🚌 717번 3분 후" (잠금화면·카드용 한 줄 요약)
    func summary(for route: Route, now: Date = Date()) -> String? {
        guard let next = upcoming(for: route, now: now).first else { return nil }
        let time = next.remaining < 60 ? "곧 도착" : "\(next.remaining / 60)분 후"
        return "🚌 \(next.arrival.routeNo)번 \(time)"
    }

    func refresh(route: Route, key: String, store: RouteStore, minInterval: TimeInterval = 45) async {
        guard !route.busRoutes.isEmpty, !route.busOrigin.isEmpty,
              let api = try? RailAPI(serviceKey: key) else { return }
        if let fetched = states[route.id]?.fetchedAt, Date().timeIntervalSince(fetched) < minInterval { return }
        if loading.contains(route.id) { return }
        loading.insert(route.id)
        defer { loading.remove(route.id) }

        var state = states[route.id] ?? State()
        do {
            if state.cityCode.isEmpty {
                let address = route.busOriginAddress.isEmpty ? route.busOrigin : route.busOriginAddress
                state.cityCode = try await api.busCityCode(forAddress: address)
            }
            if state.candidates.isEmpty {
                state.candidates = try await api.busStops(cityCode: state.cityCode, named: route.busOrigin)
                guard !state.candidates.isEmpty else { throw RailAPIError.noStation(route.busOrigin) }
            }

            if let saved = state.candidates.first(where: { $0.id == route.busStopId }) {
                state.stop = saved
                state.arrivals = try await api.busArrivals(cityCode: state.cityCode, stopId: saved.id)
            } else {
                // 같은 이름 정류장이 여러 개면(방향별) 경유버스가 가장 많이 오는 곳을 고른다.
                let wanted = Set(route.busRoutes)
                var best: (stop: BusStop, arrivals: [BusArrival], score: Int)?
                for stop in state.candidates.prefix(4) {
                    let arrivals = try await api.busArrivals(cityCode: state.cityCode, stopId: stop.id)
                    let score = Set(arrivals.map(\.routeNo)).intersection(wanted).count
                    if best == nil || score > best!.score { best = (stop, arrivals, score) }
                }
                if let best {
                    state.stop = best.stop
                    state.arrivals = best.arrivals
                    if best.score > 0, var updated = store.route(id: route.id) {
                        updated.busStopId = best.stop.id
                        updated.busStopLabel = best.stop.label
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
        states[route.id] = state
    }

    func choose(_ stop: BusStop, for route: Route, store: RouteStore) {
        if var updated = store.route(id: route.id) {
            updated.busStopId = stop.id
            updated.busStopLabel = stop.label
            store.upsert(updated)
        }
        states[route.id]?.fetchedAt = nil
    }
}
