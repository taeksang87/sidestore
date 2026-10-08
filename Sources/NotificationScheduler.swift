import Foundation
import UserNotifications

/// 출발 알림. 아이폰 안에서 예약하는 로컬 알림이라 무료 Apple ID로도 동작한다.
/// iOS는 예약 알림을 64개까지만 보관하므로, 앱을 열 때마다 앞으로 7일 치를 다시 예약한다.
enum NotificationScheduler {
    private static let prefix = "leave-"
    private static let maxPending = 60

    static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        default:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        }
    }

    static func reschedule(routes: [Route], dayOverrideRaw: String, now: Date = Date()) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(prefix) })

        let active = routes.filter(\.notifyEnabled)
        guard !active.isEmpty else { return }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        var requests: [UNNotificationRequest] = []
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)

        for offset in 0..<7 {
            guard let dayStart = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            let day = offset == 0 ? DayOverride.effective(raw: dayOverrideRaw, on: now) : DayType.automatic(for: dayStart)

            for route in active where route.notifyDays.contains(day) {
                for departure in route.times(for: day) where departure >= route.notifyFrom && departure <= route.notifyTo {
                    let leaveAt = departure - route.walkMinutes
                    let fireMinutes = leaveAt - route.notifyLead
                    guard let fireDate = calendar.date(byAdding: .minute, value: fireMinutes, to: dayStart), fireDate > now else { continue }

                    let content = UNMutableNotificationContent()
                    content.title = "🚆 \(route.name) \(TimeText.clock(departure)) 열차"
                    if route.walkMinutes > 0 {
                        content.body = "\(route.notifyLead)분 뒤 출발하세요 · \(TimeText.clock(leaveAt))까지 나가면 탑승"
                    } else {
                        content.body = "\(route.notifyLead)분 뒤 \(route.stop) 출발"
                    }
                    if let arrival = route.arrival(for: departure, day: day) ?? (route.rideMinutes > 0 ? departure + route.rideMinutes : nil),
                       !route.destination.isEmpty {
                        content.body += " · \(route.destination) \(TimeText.clock(arrival)) 도착"
                    }
                    content.sound = .default

                    let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
                    let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                    let id = "\(prefix)\(route.id.uuidString)-\(Int(fireDate.timeIntervalSince1970))"
                    requests.append(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
                }
            }
        }

        for request in requests.sorted(by: { fireDate($0) < fireDate($1) }).prefix(maxPending) {
            try? await center.add(request)
        }
    }

    static func pendingCount(for route: Route) async -> Int {
        await UNUserNotificationCenter.current().pendingNotificationRequests()
            .filter { $0.identifier.hasPrefix("\(prefix)\(route.id.uuidString)") }
            .count
    }

    private static func fireDate(_ request: UNNotificationRequest) -> Date {
        (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() ?? .distantFuture
    }
}
