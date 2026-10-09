import ActivityKit
import Foundation

/// 잠금화면·다이나믹 아일랜드 실시간 현황
struct CommuteActivityAttributes: ActivityAttributes {
    struct Train: Codable, Hashable {
        var departure: Date
        /// 이 시각까지 출발해야 탈 수 있음 (역까지 이동 시간 반영)
        var leaveBy: Date
        var arrival: Date?
        var arrivalIsExact: Bool
        /// "무궁화호 1886"
        var label: String?
    }

    struct ContentState: Codable, Hashable {
        /// 앞으로 탈 수 있는 열차 (최대 4편). 앱이 꺼져 있어도 각 열차 카운트다운은 계속 흐른다.
        var trains: [Train]
        var expressText: String?
        var busText: String?
        /// 오늘 좌석 ("🎫 06:11 3호차 12A")
        var seatText: String?
        var updatedAt: Date
    }

    var routeID: String
    var routeName: String
    var stop: String
    var destination: String
    var walkMinutes: Int
    /// 누르면 코레일톡 열기
    var opensKorail: Bool
    /// 자동(시간·단축어)으로 띄운 것인지. 자동으로 띄운 것은 시간대가 지나면 자동으로 끈다. (예전 버전은 nil)
    var autoStarted: Bool?

    /// 잠금화면·다이나믹 아일랜드를 눌렀을 때 열 주소 (앱이 받아서 코레일톡으로 넘긴다)
    var tapURL: URL? {
        URL(string: opensKorail ? "commutetimer://korail" : "commutetimer://route/\(routeID)")
    }
}

extension Route {
    /// 지금 기준 다음 열차들을 Live Activity·위젯용 Date로 바꾼다.
    func activityTrains(from now: Date, day: DayType, limit: Int = 4) -> [CommuteActivityAttributes.Train] {
        upcoming(from: now, day: day, limit: limit).map { d in
            let departure = now.addingTimeInterval(Double(d.secondsUntil))
            var arrival: Date?
            var exact = false
            if let estimate = arrivalEstimate(for: d) {
                var minutes = estimate.minutes - d.minutes
                if minutes < 0 { minutes += 1440 }
                arrival = departure.addingTimeInterval(Double(minutes * 60))
                exact = estimate.exact
            }
            return .init(
                departure: departure,
                leaveBy: now.addingTimeInterval(Double(d.leaveIn)),
                arrival: arrival,
                arrivalIsExact: exact,
                label: trainLabel(for: d.minutes, day: d.day)
            )
        }
    }

    func nextExpressText(from now: Date) -> String? {
        guard let express = nextExpress(from: now) else { return nil }
        var text = "\(express.type) \(TimeText.clock(express.departure))→\(express.station) \(TimeText.clock(express.arrival))"
        if let final = transferArrival(for: express) {
            text += " (환승 후 \(destination) \(TimeText.clock(final)))"
        }
        return text
    }
}

extension TimeText {
    static func clock(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}
