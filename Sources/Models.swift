import Foundation

enum CommuteDirection: String, Codable, CaseIterable, Identifiable {
    case toWork
    case toHome

    var id: String { rawValue }

    var title: String {
        switch self {
        case .toWork: return "출근"
        case .toHome: return "퇴근"
        }
    }

    /// 오후 1시 전에는 출근, 그 뒤에는 퇴근 화면을 먼저 보여준다.
    static func suggested(for date: Date = Date()) -> CommuteDirection {
        Calendar.current.component(.hour, from: date) < 13 ? .toWork : .toHome
    }
}

enum DayType: String, Codable, CaseIterable, Identifiable {
    case weekday
    case saturday
    case holiday

    var id: String { rawValue }

    var title: String {
        switch self {
        case .weekday: return "평일"
        case .saturday: return "토요일"
        case .holiday: return "일요일·공휴일"
        }
    }

    var shortTitle: String {
        switch self {
        case .weekday: return "평일"
        case .saturday: return "토"
        case .holiday: return "휴일"
        }
    }

    static func automatic(for date: Date) -> DayType {
        switch Calendar.current.component(.weekday, from: date) {
        case 1: return .holiday
        case 7: return .saturday
        default: return .weekday
        }
    }
}

/// 공휴일처럼 요일로 판단할 수 없는 날을 위해, 오늘 하루만 적용되는 수동 지정 값.
/// AppStorage에 "yyyy-MM-dd|holiday" 형태로 저장한다.
enum DayOverride {
    static let storageKey = "dayOverride"

    static func effective(raw: String, on date: Date = Date()) -> DayType {
        let parts = raw.split(separator: "|")
        if parts.count == 2, String(parts[0]) == dayKey(date), let day = DayType(rawValue: String(parts[1])) {
            return day
        }
        return .automatic(for: date)
    }

    static func isActive(raw: String, on date: Date = Date()) -> Bool {
        effective(raw: raw, on: date) != .automatic(for: date)
    }

    static func raw(for day: DayType, on date: Date = Date()) -> String {
        day == .automatic(for: date) ? "" : "\(dayKey(date))|\(day.rawValue)"
    }

    private static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

enum Transport: String, Codable, CaseIterable, Identifiable {
    case bus
    case subway
    case train
    case shuttle
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bus: return "버스"
        case .subway: return "지하철"
        case .train: return "기차·전철"
        case .shuttle: return "셔틀"
        case .other: return "기타"
        }
    }

    var symbol: String {
        switch self {
        case .bus: return "bus.fill"
        case .subway: return "tram.fill"
        case .train: return "train.side.front.car"
        case .shuttle: return "bus.doubledecker.fill"
        case .other: return "car.fill"
        }
    }
}

/// ITX·KTX처럼 따로 표시하는 직통열차
struct ExpressTrain: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var type: String
    var number: String
    var departure: Int
    var arrival: Int
    var station: String
    var price: Int

    /// "KTX-이음 711 17:51 18:26 신해운대 8400" 한 줄 형식
    var line: String {
        "\(type) \(number) \(TimeText.clock(departure)) \(TimeText.clock(arrival)) \(station) \(price)"
    }

    static func parse(_ text: String) -> (trains: [ExpressTrain], invalidLines: [String]) {
        var trains: [ExpressTrain] = []
        var invalid: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let parts = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if parts.isEmpty { continue }
            guard parts.count == 6,
                  let dep = TimeText.parse(parts[2]).times.first,
                  let arr = TimeText.parse(parts[3]).times.first,
                  let price = Int(parts[5].replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "원", with: ""))
            else {
                invalid.append(rawLine)
                continue
            }
            trains.append(ExpressTrain(type: parts[0], number: parts[1], departure: dep, arrival: arr, station: parts[4], price: price))
        }
        return (trains.sorted { $0.departure < $1.departure }, invalid)
    }
}

struct Route: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String = ""
    /// 타는 역/정류장
    var stop: String = ""
    /// 내리는 역 (도착 예상 시각 표시용)
    var destination: String = ""
    var direction: CommuteDirection = .toWork
    var transport: Transport = .bus
    /// 회사(집)에서 나와 플랫폼에 서기까지 걸리는 시간
    var walkMinutes: Int = 0
    /// 탑승 후 도착역까지 걸리는 시간
    var rideMinutes: Int = 0
    /// 자정 기준 분(예: 07:30 → 450), 오름차순
    var weekday: [Int] = []
    var saturday: [Int] = []
    var holiday: [Int] = []

    var expresses: [ExpressTrain] = []
    /// 직통열차가 도착역이 아닌 곳에 설 때, 도착역까지 환승 대기+이동 시간
    var transferMinutes: Int = 0
    var transferFare: Int = 0

    /// 타는 역 좌표 (날씨·길찾기용)
    var latitude: Double?
    var longitude: Double?

    /// 타는 역까지 가는 버스 정보
    var busOrigin: String = ""
    var busOriginAddress: String = ""
    var busRoutes: [String] = []

    /// 철도 API(TAGO)로 시간표를 자동으로 받아올지
    var autoSync: Bool = false
    /// 지하철정보 API 방향 코드: U(상행) / D(하행)
    var syncDirection: String = "U"
    /// 직통열차가 도착역 대신 서는 환승역 (예: 신해운대)
    var transferStation: String = ""
    /// "weekday-1056" → 도착 시각(분). API로 받은 실제 도착 시각
    var arrivals: [String: Int] = [:]
    var timetableSyncedAt: Date?
    /// 직통열차를 마지막으로 받은 날짜 (yyyyMMdd)
    var expressSyncedDay: String = ""

    func arrival(for departure: Int, day: DayType) -> Int? {
        arrivals["\(day.rawValue)-\(departure)"]
    }

    func times(for day: DayType) -> [Int] {
        switch day {
        case .weekday: return weekday
        case .saturday: return saturday
        case .holiday: return holiday
        }
    }

    mutating func setTimes(_ times: [Int], for day: DayType) {
        let cleaned = Array(Set(times)).sorted()
        switch day {
        case .weekday: weekday = cleaned
        case .saturday: saturday = cleaned
        case .holiday: holiday = cleaned
        }
    }
}

extension Route {
    enum CodingKeys: String, CodingKey {
        case id, name, stop, destination, direction, transport, walkMinutes, rideMinutes
        case weekday, saturday, holiday
        case expresses, transferMinutes, transferFare
        case latitude, longitude
        case busOrigin, busOriginAddress, busRoutes
        case autoSync, syncDirection, transferStation, arrivals, timetableSyncedAt, expressSyncedDay
    }

    /// 새 버전에서 항목이 추가돼도 예전에 저장한 데이터를 읽을 수 있도록, 없는 값은 기본값으로 채운다.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        stop = try c.decodeIfPresent(String.self, forKey: .stop) ?? ""
        destination = try c.decodeIfPresent(String.self, forKey: .destination) ?? ""
        direction = try c.decodeIfPresent(CommuteDirection.self, forKey: .direction) ?? .toWork
        transport = try c.decodeIfPresent(Transport.self, forKey: .transport) ?? .bus
        walkMinutes = try c.decodeIfPresent(Int.self, forKey: .walkMinutes) ?? 0
        rideMinutes = try c.decodeIfPresent(Int.self, forKey: .rideMinutes) ?? 0
        weekday = try c.decodeIfPresent([Int].self, forKey: .weekday) ?? []
        saturday = try c.decodeIfPresent([Int].self, forKey: .saturday) ?? []
        holiday = try c.decodeIfPresent([Int].self, forKey: .holiday) ?? []
        expresses = try c.decodeIfPresent([ExpressTrain].self, forKey: .expresses) ?? []
        transferMinutes = try c.decodeIfPresent(Int.self, forKey: .transferMinutes) ?? 0
        transferFare = try c.decodeIfPresent(Int.self, forKey: .transferFare) ?? 0
        latitude = try c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
        busOrigin = try c.decodeIfPresent(String.self, forKey: .busOrigin) ?? ""
        busOriginAddress = try c.decodeIfPresent(String.self, forKey: .busOriginAddress) ?? ""
        busRoutes = try c.decodeIfPresent([String].self, forKey: .busRoutes) ?? []
        autoSync = try c.decodeIfPresent(Bool.self, forKey: .autoSync) ?? false
        syncDirection = try c.decodeIfPresent(String.self, forKey: .syncDirection) ?? "U"
        transferStation = try c.decodeIfPresent(String.self, forKey: .transferStation) ?? ""
        arrivals = try c.decodeIfPresent([String: Int].self, forKey: .arrivals) ?? [:]
        timetableSyncedAt = try c.decodeIfPresent(Date.self, forKey: .timetableSyncedAt)
        expressSyncedDay = try c.decodeIfPresent(String.self, forKey: .expressSyncedDay) ?? ""
    }
}

struct Departure {
    /// 자정 기준 출발 시각(분)
    let minutes: Int
    /// 지금부터 출발까지 남은 초
    let secondsUntil: Int
    /// 지금부터 집(회사)을 나서야 할 때까지 남은 초 — 음수면 이미 늦음
    let leaveIn: Int
    let isTomorrow: Bool
    /// 이 열차가 속한 시간표 (내일 첫차면 내일 요일)
    let day: DayType
}

extension Route {
    /// 아직 출발하지 않은 열차. 오늘 운행이 끝났으면 내일 첫차부터 보여준다.
    func upcoming(from date: Date, day: DayType, limit: Int = 3) -> [Departure] {
        let nowSeconds = TimeText.secondsOfDay(date)
        let walk = walkMinutes * 60
        let today = times(for: day)
            .filter { $0 * 60 > nowSeconds }
            .prefix(limit)
            .map { Departure(minutes: $0, secondsUntil: $0 * 60 - nowSeconds, leaveIn: $0 * 60 - walk - nowSeconds, isTomorrow: false, day: day) }
        if !today.isEmpty { return Array(today) }

        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date
        let untilMidnight = 86400 - nowSeconds
        let tomorrowDay = DayType.automatic(for: tomorrow)
        return times(for: tomorrowDay)
            .prefix(limit)
            .map { Departure(minutes: $0, secondsUntil: untilMidnight + $0 * 60, leaveIn: untilMidnight + $0 * 60 - walk, isTomorrow: true, day: tomorrowDay) }
    }

    /// 지금 출발하면 탈 수 있는 다음 직통열차
    func nextExpress(from date: Date) -> ExpressTrain? {
        let readyAt = TimeText.secondsOfDay(date) + walkMinutes * 60
        return expresses.first { $0.departure * 60 >= readyAt }
    }

    /// 직통열차가 도착역이 아닌 역에 설 때, 최종 도착 시각(분)
    func transferArrival(for train: ExpressTrain) -> Int? {
        guard !destination.isEmpty, train.station != destination, transferMinutes > 0 else { return nil }
        return train.arrival + transferMinutes
    }

    var hasCoordinate: Bool { latitude != nil && longitude != nil }

    /// API로 받은 실제 도착 시각, 없으면 탑승 시간으로 계산한 예상 시각
    func arrivalEstimate(for departure: Departure) -> (minutes: Int, exact: Bool)? {
        if let exact = arrival(for: departure.minutes, day: departure.day) { return (exact, true) }
        return rideMinutes > 0 ? (departure.minutes + rideMinutes, false) : nil
    }

    static var samples: [Route] {
        var donghae = Route(
            name: "동해선",
            stop: "태화강",
            destination: "센텀",
            direction: .toHome,
            transport: .train,
            walkMinutes: 20,
            rideMinutes: 58
        )
        // 2026-08-28 조정안(개정 시간표) 기준, 태화강→부전 상행
        let weekdayTimes = """
        05:36 05:52
        06:20 06:35 06:47
        07:06 07:25 07:43
        08:02 08:18
        09:03 09:18 09:30 09:51
        10:15 10:46
        11:18 11:41
        12:05 12:49
        13:21 13:45
        14:11 14:42
        15:26 15:55
        16:21 16:49
        17:17 17:43
        18:03 18:22 18:38 18:54
        19:10 19:31 19:58
        20:19 20:40 20:58
        21:13 21:42
        22:22
        23:00 23:30
        """
        let weekendTimes = """
        05:35
        06:00 06:22 06:41
        07:06 07:30
        08:04 08:22 08:49
        09:31 09:56
        10:08 10:32 10:56
        11:21 11:46
        12:12 12:40
        13:01 13:25 13:48
        14:11 14:42
        15:08 15:40
        16:04 16:29 16:59
        17:15 17:43
        18:14 18:40
        19:08 19:31 19:54
        20:16 20:38 20:58
        21:13 21:50
        22:21
        23:00
        """
        donghae.setTimes(TimeText.parse(weekdayTimes).times, for: .weekday)
        donghae.setTimes(TimeText.parse(weekendTimes).times, for: .saturday)
        donghae.setTimes(TimeText.parse(weekendTimes).times, for: .holiday)

        donghae.expresses = ExpressTrain.parse("""
        KTX-이음 711 17:51 18:26 신해운대 8400
        ITX-마음 1603 19:23 20:16 센텀 5200
        KTX-이음 713 19:46 20:24 센텀 8400
        ITX-마음 1814 20:54 21:48 센텀 5200
        """).trains
        // 신해운대 환승 대기 14분 + 센텀까지 7분
        donghae.transferMinutes = 21
        donghae.transferFare = 1600
        donghae.transferStation = "신해운대"
        donghae.autoSync = true

        donghae.latitude = 35.5384
        donghae.longitude = 129.3372

        donghae.busOrigin = "명촌차고지"
        donghae.busOriginAddress = "울산광역시 북구 산업로 768"
        donghae.busRoutes = [
            "217", "417", "712", "713", "714", "718", "721", "723", "725",
            "728", "732", "734", "741", "742", "743", "744", "752", "753",
            "763", "773"
        ]
        return [donghae]
    }
}

enum TimeText {
    static func secondsOfDay(_ date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        return (c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60 + (c.second ?? 0)
    }

    static func minutesOfDay(_ date: Date) -> Int {
        secondsOfDay(date) / 60
    }

    static func clock(_ minutes: Int) -> String {
        let m = ((minutes % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", m / 60, m % 60)
    }

    static func countdown(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s >= 3600 {
            return "\(s / 3600)시간 \(s % 3600 / 60)분"
        }
        return String(format: "%d분 %02d초", s / 60, s % 60)
    }

    static func won(_ amount: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return (formatter.string(from: NSNumber(value: amount)) ?? "\(amount)") + "원"
    }

    static func series(start: Int, end: Int, every: Int) -> [Int] {
        guard every > 0, start <= end else { return [] }
        return Array(stride(from: start, through: end, by: every))
    }

    struct ParseResult {
        let times: [Int]
        let invalid: [String]
    }

    /// "07:05 07:20, 0735\n8:00" 처럼 띄어쓰기·쉼표·줄바꿈으로 구분된 시각을 읽는다.
    static func parse(_ text: String) -> ParseResult {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",/|·\""))
        var times = Set<Int>()
        var invalid: [String] = []

        for token in text.components(separatedBy: separators) where !token.isEmpty {
            var hour: Int?
            var minute: Int?
            if token.contains(":") {
                let parts = token.split(separator: ":", omittingEmptySubsequences: false)
                if parts.count == 2, parts[1].count == 2 {
                    hour = Int(parts[0])
                    minute = Int(parts[1])
                }
            } else if (3...4).contains(token.count), let value = Int(token) {
                hour = value / 100
                minute = value % 100
            }

            if let hour, let minute, (0..<24).contains(hour), (0..<60).contains(minute) {
                times.insert(hour * 60 + minute)
            } else {
                invalid.append(token)
            }
        }
        return ParseResult(times: times.sorted(), invalid: invalid)
    }

    /// 시간대별로 한 줄씩 묶어서 편집하기 쉬운 텍스트로 만든다.
    static func format(_ times: [Int]) -> String {
        let grouped = Dictionary(grouping: times.sorted()) { $0 / 60 }
        return grouped.keys.sorted()
            .map { hour in grouped[hour, default: []].map { clock($0) }.joined(separator: " ") }
            .joined(separator: "\n")
    }
}
