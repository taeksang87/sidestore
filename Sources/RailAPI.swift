import Foundation

/// 공공데이터포털 국토교통부(TAGO) 열차정보·지하철정보 API
/// - 지하철정보: 동해선 같은 광역전철의 역별 시간표 (평일/토/휴일, 상·하행)
/// - 열차정보: KTX·ITX·무궁화 출발/도착 시각과 요금 (날짜별)
enum RailAPIError: LocalizedError {
    case noKey
    case server(String)
    case noStation(String)
    case empty(String)

    var errorDescription: String? {
        switch self {
        case .noKey: return "설정에서 공공데이터포털 인증키를 먼저 입력하세요."
        case .server(let message): return message
        case .noStation(let name): return "‘\(name)’ 역을 찾지 못했어요. 역 이름을 확인하세요."
        case .empty(let what): return "\(what) 결과가 비어 있어요."
        }
    }
}

struct RailAPI {
    static let keyStorage = "railApiKey"
    private static let base = "https://apis.data.go.kr/1613000/"
    private static let trainStationCache = "trainStationIds"

    let serviceKey: String

    init(serviceKey: String) throws {
        let trimmed = serviceKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RailAPIError.noKey }
        self.serviceKey = trimmed
    }

    // MARK: - 공통 요청

    func request(_ path: String, _ params: [String: String]) async throws -> [[String: Any]] {
        // 디코딩 키(+, /, = 포함)와 인코딩 키(%2B 등) 둘 다 받아준다.
        let key = serviceKey.contains("%") ? serviceKey : Self.encode(serviceKey)
        var query = "serviceKey=\(key)&_type=json"
        for (name, value) in params {
            query += "&\(name)=\(Self.encode(value))"
        }
        guard var components = URLComponents(string: Self.base + path) else { throw RailAPIError.server("잘못된 주소") }
        components.percentEncodedQuery = query
        guard let url = components.url else { throw RailAPIError.server("잘못된 주소") }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: request)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw RailAPIError.server(Self.friendlyError(text))
        }
        if let envelope = json["OpenAPI_ServiceResponse"] as? [String: Any],
           let header = envelope["cmmMsgHeader"] as? [String: Any] {
            throw RailAPIError.server(Self.friendlyError(Self.string(header["errMsg"]) + " " + Self.string(header["returnAuthMsg"])))
        }
        guard let response = json["response"] as? [String: Any] else {
            throw RailAPIError.server("알 수 없는 응답이에요.")
        }
        if let header = response["header"] as? [String: Any] {
            let code = Self.string(header["resultCode"])
            if code != "00" && code != "0" && !code.isEmpty {
                throw RailAPIError.server(Self.friendlyError(Self.string(header["resultMsg"])))
            }
        }
        guard let body = response["body"] as? [String: Any],
              let items = body["items"] as? [String: Any] else { return [] }
        if let list = items["item"] as? [[String: Any]] { return list }
        if let one = items["item"] as? [String: Any] { return [one] }
        return []
    }

    private static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? text
    }

    static func string(_ value: Any?) -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return ""
    }

    /// "053600"(HHmmss) 또는 "20261008175100"(yyyyMMddHHmmss) → 자정 기준 분
    static func minutes(_ value: Any?) -> Int? {
        let digits = string(value).filter(\.isNumber)
        guard digits.count >= 3, Int(digits) != 0 else { return nil }
        let hhmmss = digits.count >= 12 ? String(digits.dropFirst(8)) : digits
        let padded = String(repeating: "0", count: max(0, 6 - hhmmss.count)) + hhmmss
        guard let h = Int(padded.prefix(2)), let m = Int(padded.dropFirst(2).prefix(2)) else { return nil }
        return h * 60 + m
    }

    private static func friendlyError(_ raw: String) -> String {
        if raw.contains("SERVICE_KEY_IS_NOT_REGISTERED") || raw.contains("등록되지 않은") {
            return "인증키가 등록되지 않았어요. 방금 발급했다면 1~2시간 뒤 다시 시도하고, 열차정보·지하철정보 둘 다 활용신청했는지 확인하세요."
        }
        if raw.contains("LIMITED_NUMBER_OF_SERVICE_REQUESTS") { return "오늘 API 호출 한도를 넘었어요. 내일 다시 시도하세요." }
        if raw.contains("SERVICE_ACCESS_DENIED") { return "이 API 사용 권한이 없어요. 공공데이터포털에서 활용신청을 확인하세요." }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "서버 응답 오류" : String(trimmed.prefix(200))
    }

    // MARK: - 연결 확인

    func testConnection() async throws -> String {
        let cities = try await request("TrainInfo/GetCtyCodeList", [:])
        let subway = try await request("SubwayInfo/GetKwrdFndSubwaySttnList", ["subwayStationName": "센텀", "numOfRows": "10", "pageNo": "1"])
        var result = "열차정보 OK (도시 \(cities.count)곳) · 지하철정보 OK (‘센텀’ 검색 \(subway.count)건)"
        do {
            let busCities = try await request("BusSttnInfoInqireService/getCtyCodeList", [:])
            result += " · 버스정보 OK (도시 \(busCities.count)곳)"
        } catch {
            result += "
버스정보: \(error.localizedDescription)"
        }
        return result
    }

    // MARK: - 지하철정보 (광역전철 시간표)

    func subwayStationId(named name: String, lineHint: String) async throws -> String {
        let items = try await request("SubwayInfo/GetKwrdFndSubwaySttnList", ["subwayStationName": name, "numOfRows": "100", "pageNo": "1"])
        let hint = lineHint.replacingOccurrences(of: "선", with: "").trimmingCharacters(in: .whitespaces)
        func stationName(_ item: [String: Any]) -> String {
            let n = Self.string(item["subwayStationName"])
            return n.isEmpty ? Self.string(item["subwayStationNm"]) : n
        }
        func score(_ item: [String: Any]) -> Int {
            var s = 0
            let n = stationName(item)
            if n == name || n == name + "역" || n + "역" == name { s += 2 }
            if !hint.isEmpty && Self.string(item["subwayRouteName"]).contains(hint) { s += 3 }
            return s
        }
        guard let best = items.max(by: { score($0) < score($1) }),
              !Self.string(best["subwayStationId"]).isEmpty else {
            throw RailAPIError.noStation(name)
        }
        return Self.string(best["subwayStationId"])
    }

    private static func dailyCode(_ day: DayType) -> String {
        switch day {
        case .weekday: return "01"
        case .saturday: return "02"
        case .holiday: return "03"
        }
    }

    /// 역 시간표. useArrival이면 도착 시각 우선(내리는 역), 아니면 출발 시각 우선(타는 역)
    func subwayTimes(stationId: String, day: DayType, direction: String, useArrival: Bool) async throws -> [Int] {
        let items = try await request("SubwayInfo/GetSubwaySttnAcctoSchdulList", [
            "subwayStationId": stationId,
            "dailyTypeCode": Self.dailyCode(day),
            "upDownTypeCode": direction,
            "numOfRows": "1000",
            "pageNo": "1"
        ])
        let times = items.compactMap { item -> Int? in
            let dep = Self.minutes(item["depTime"])
            let arr = Self.minutes(item["arrTime"])
            return useArrival ? (arr ?? dep) : (dep ?? arr)
        }
        return Array(Set(times)).sorted()
    }

    /// 열차번호가 없으므로, 출발·도착 시각 차이가 가장 일정한 소요시간을 찾아 짝을 맞춘다.
    static func matchArrivals(departures: [Int], arrivals: [Int]) -> (ride: Int, map: [Int: Int])? {
        guard !departures.isEmpty, !arrivals.isEmpty else { return nil }
        // 자정을 넘겨 도착하는 열차를 위해 새벽 시각은 +24시간도 넣어 둔다.
        var arrivalSet = Set(arrivals)
        for a in arrivals where a < 240 { arrivalSet.insert(a + 1440) }

        var bestRide = 0
        var bestCount = 0
        for ride in 3...240 {
            let count = departures.filter { t in (-1...1).contains { arrivalSet.contains(t + ride + $0) } }.count
            if count > bestCount {
                bestCount = count
                bestRide = ride
            }
        }
        guard bestCount >= max(3, departures.count / 3) else { return nil }

        var map: [Int: Int] = [:]
        for t in departures {
            for offset in [0, -1, 1, -2, 2, -3, 3] where arrivalSet.contains(t + bestRide + offset) {
                map[t] = (t + bestRide + offset) % 1440
                break
            }
        }
        return (bestRide, map)
    }

    // MARK: - 열차정보 (KTX·ITX·무궁화)

    func trainStationId(named name: String) async throws -> String {
        let defaults = UserDefaults.standard
        var cache = defaults.dictionary(forKey: Self.trainStationCache) as? [String: String] ?? [:]
        if cache.isEmpty {
            let cities = try await request("TrainInfo/GetCtyCodeList", [:])
            for city in cities {
                let code = Self.string(city["citycode"])
                guard !code.isEmpty else { continue }
                let stations = try await request("TrainInfo/GetCtyAcctoTrainSttnList", ["cityCode": code, "numOfRows": "1000", "pageNo": "1"])
                for station in stations {
                    let id = Self.string(station["nodeid"])
                    let stationName = Self.string(station["nodename"])
                    if !id.isEmpty && !stationName.isEmpty { cache[stationName] = id }
                }
            }
            guard !cache.isEmpty else { throw RailAPIError.empty("열차역 목록") }
            defaults.set(cache, forKey: Self.trainStationCache)
        }
        let bare = name.hasSuffix("역") ? String(name.dropLast()) : name
        if let id = cache[bare] ?? cache[bare + "역"] { return id }
        throw RailAPIError.noStation(name)
    }

    func trains(from depId: String, to arrId: String, on date: Date) async throws -> [ExpressTrain] {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let ymd = String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        let items = try await request("TrainInfo/GetStrtpntAlocFndTrainInfo", [
            "depPlaceId": depId,
            "arrPlaceId": arrId,
            "depPlandTime": ymd,
            "numOfRows": "200",
            "pageNo": "1"
        ])
        return items.compactMap { item in
            guard let dep = Self.minutes(item["depplandtime"]), let arr = Self.minutes(item["arrplandtime"]) else { return nil }
            return ExpressTrain(
                type: Self.string(item["traingradename"]),
                number: Self.string(item["trainno"]),
                departure: dep,
                arrival: arr,
                station: Self.string(item["arrplacename"]),
                price: Int(Self.string(item["adultcharge"])) ?? 0
            )
        }
    }
}

// MARK: - 노선 동기화

enum RailSync {
    struct Result {
        var route: Route
        var messages: [String]
    }

    static func todayKey(_ date: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 시간표(광역전철)와 오늘 직통열차를 받아 노선에 반영한다. 일부가 실패해도 성공한 부분은 반영한다.
    static func sync(_ original: Route, key: String, timetable: Bool, express: Bool) async throws -> Result {
        let api = try RailAPI(serviceKey: key)
        var route = original
        var messages: [String] = []
        var failures: [String] = []

        if timetable {
            do {
                messages.append(try await syncTimetable(&route, api: api))
            } catch {
                failures.append("시간표: \(error.localizedDescription)")
            }
        }

        if express, !route.destination.isEmpty {
            do {
                messages.append(try await syncExpresses(&route, api: api))
            } catch {
                failures.append("직통열차: \(error.localizedDescription)")
            }
        }

        if messages.isEmpty, let first = failures.first {
            throw RailAPIError.server(first)
        }
        return Result(route: route, messages: messages + failures)
    }

    private static func syncTimetable(_ route: inout Route, api: RailAPI) async throws -> String {
        let depId = try await api.subwayStationId(named: route.stop, lineHint: route.name)
        var arrId: String?
        if !route.destination.isEmpty {
            arrId = try await api.subwayStationId(named: route.destination, lineHint: route.name)
        }

        // 설정한 방향에 출발 열차가 없으면 반대 방향으로 시도
        var direction = route.syncDirection
        var weekdayDeps = try await api.subwayTimes(stationId: depId, day: .weekday, direction: direction, useArrival: false)
        if weekdayDeps.isEmpty {
            direction = direction == "U" ? "D" : "U"
            weekdayDeps = try await api.subwayTimes(stationId: depId, day: .weekday, direction: direction, useArrival: false)
        }
        guard !weekdayDeps.isEmpty else { throw RailAPIError.empty("\(route.stop) 시간표") }

        var counts: [String] = []
        var arrivals: [String: Int] = [:]
        var rides: [Int] = []

        for day in DayType.allCases {
            var deps = weekdayDeps
            if day != .weekday {
                deps = try await api.subwayTimes(stationId: depId, day: day, direction: direction, useArrival: false)
            }
            guard !deps.isEmpty else {
                counts.append("\(day.shortTitle) 없음")
                continue
            }
            route.setTimes(deps, for: day)
            counts.append("\(day.shortTitle) \(deps.count)회")

            if let arrId {
                let arrs = try await api.subwayTimes(stationId: arrId, day: day, direction: direction, useArrival: true)
                if let match = RailAPI.matchArrivals(departures: deps, arrivals: arrs) {
                    rides.append(match.ride)
                    for (dep, arr) in match.map {
                        arrivals["\(day.rawValue)-\(dep)"] = arr
                    }
                }
            }
        }

        route.syncDirection = direction
        route.arrivals = arrivals
        if let ride = rides.first { route.rideMinutes = ride }
        route.timetableSyncedAt = Date()

        var text = "\(route.name) 시간표: " + counts.joined(separator: " · ")
        if arrId != nil {
            text += arrivals.isEmpty ? " (도착 시각 매칭 실패, 예상 시간 사용)" : " · \(route.destination) 도착 \(arrivals.count)건 연결"
        }
        return text
    }

    private static func syncExpresses(_ route: inout Route, api: RailAPI) async throws -> String {
        let depId = try await api.trainStationId(named: route.stop)
        let destId = try await api.trainStationId(named: route.destination)
        let today = Date()

        var byNumber: [String: ExpressTrain] = [:]
        for train in try await api.trains(from: depId, to: destId, on: today) {
            byNumber[train.number] = train
        }
        // 도착역에 서지 않는 열차는 환승역 기준으로 받아 둔다.
        if !route.transferStation.isEmpty, let transferId = try? await api.trainStationId(named: route.transferStation) {
            for train in try await api.trains(from: depId, to: transferId, on: today) where byNumber[train.number] == nil {
                byNumber[train.number] = train
            }
        }

        route.expresses = byNumber.values.sorted { $0.departure < $1.departure }
        route.expressSyncedDay = todayKey(today)
        return route.expresses.isEmpty
            ? "오늘 \(route.stop)→\(route.destination) 직통열차 없음"
            : "오늘 직통열차 \(route.expresses.count)편"
    }

    /// 앱을 열 때: 직통열차는 하루 한 번, 광역전철 시간표는 7일에 한 번 새로 받는다.
    @MainActor
    static func autoSync(store: RouteStore, key: String) async {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        for route in store.routes where route.autoSync {
            let needTimetable = route.timetableSyncedAt.map { Date().timeIntervalSince($0) > 7 * 86400 } ?? true
            let needExpress = route.expressSyncedDay != todayKey()
            guard needTimetable || needExpress else { continue }
            if let result = try? await sync(route, key: key, timetable: needTimetable, express: needExpress),
               let current = store.route(id: route.id) {
                // 동기화하는 동안 사용자가 편집했을 수 있으니 API 항목만 덮어쓴다.
                var merged = current
                merged.weekday = result.route.weekday
                merged.saturday = result.route.saturday
                merged.holiday = result.route.holiday
                merged.arrivals = result.route.arrivals
                merged.rideMinutes = result.route.rideMinutes
                merged.syncDirection = result.route.syncDirection
                merged.timetableSyncedAt = result.route.timetableSyncedAt
                merged.expresses = result.route.expresses
                merged.expressSyncedDay = result.route.expressSyncedDay
                store.upsert(merged)
            }
        }
    }
}
