import Foundation
import UserNotifications

/// 출발 알림. 아이폰 안에서 예약하는 로컬 알림이라 무료 Apple ID로도 동작한다.
/// iOS는 예약 알림을 64개까지만 보관하므로, 앱을 열 때마다 앞으로 7일 치를 다시 예약한다.
enum NotificationScheduler {
    private static let prefix = "leave-"
    private static let livePrefix = "live-"
    private static let voicePrefix = "voice-"
    /// 음성 안내는 한 번에 최대 2시간 치
    private static let voiceHorizon: TimeInterval = 2 * 3600
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
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter {
            $0.hasPrefix(prefix) || $0.hasPrefix(livePrefix) || $0.hasPrefix(voicePrefix)
        })
        await removeDeliveredVoice()

        let running = await MainActor.run { LiveActivityManager.runningRouteIDs }
        let voiceRoutes = routes.filter { $0.voiceEnabled && running.contains($0.id.uuidString) }
        let active = routes.filter(\.notifyEnabled)
        let liveRoutes = routes.filter(\.liveAutoStart)
        guard !active.isEmpty || !liveRoutes.isEmpty || !voiceRoutes.isEmpty else { return }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        var requests: [UNNotificationRequest] = []
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)

        // 에어팟 음성 안내: 실시간 현황이 켜진 노선만, N분마다 ‘다음 열차 출발까지’
        let todayType = DayOverride.effective(raw: dayOverrideRaw, on: now)
        for route in voiceRoutes {
            requests += voiceRequests(for: route, day: todayType, now: now, calendar: calendar)
        }

        for offset in 0..<7 {
            guard let dayStart = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            let day = offset == 0 ? DayOverride.effective(raw: dayOverrideRaw, on: now) : DayType.automatic(for: dayStart)

            // 잠금화면 실시간 현황 시작 알림: 누르면 앱이 열리면서 자동으로 시작된다.
            for route in liveRoutes where route.liveAutoDays.contains(day) && route.visibleTimes(for: day).contains(where: { $0 >= route.liveAutoFrom }) {
                guard let fireDate = calendar.date(byAdding: .minute, value: route.liveAutoFrom, to: dayStart), fireDate > now else { continue }
                let content = UNMutableNotificationContent()
                content.title = "🔒 \(route.name) \(route.direction.title) 시간표"
                content.body = "탭하면 다음 열차 카운트다운을 잠금화면에 띄워요."
                if let seat = route.seatText(on: dayStart) { content.body += " \(seat)" }
                content.sound = nil
                let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                let id = "\(livePrefix)\(route.id.uuidString)-\(Int(fireDate.timeIntervalSince1970))"
                requests.append(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            }

            for route in active where route.notifyDays.contains(day) {
                for departure in route.visibleTimes(for: day) where departure >= route.notifyFrom && departure <= route.notifyTo {
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

    private static func voiceRequests(for route: Route, day: DayType, now: Date, calendar: Calendar) -> [UNNotificationRequest] {
        let interval = max(1, route.voiceInterval)
        let today = calendar.startOfDay(for: now)
        // 다음 N분 단위 시각부터 (예: 5분 간격이면 18:05, 18:10 …)
        let nowMinutes = TimeText.minutesOfDay(now)
        var minutes = (nowMinutes / interval + 1) * interval
        let endMinutes = min(route.liveAutoStart ? route.liveAutoUntil : 24 * 60, nowMinutes + Int(voiceHorizon / 60))
        var requests: [UNNotificationRequest] = []

        while minutes < endMinutes {
            defer { minutes += interval }
            guard let fireDate = calendar.date(byAdding: .minute, value: minutes, to: today),
                  let next = route.upcoming(from: fireDate, day: day, limit: 1).first,
                  !next.isTomorrow else { continue }

            let content = UNMutableNotificationContent()
            content.title = "\(route.name) \(TimeText.clock(next.minutes)) 열차"
            let toDeparture = max(0, next.secondsUntil / 60)
            if route.walkMinutes > 0 && next.leaveIn > 0 {
                content.body = "출발까지 \(toDeparture)분, \(TimeText.clock(next.minutes - route.walkMinutes))까지 나가세요."
            } else if route.walkMinutes > 0 {
                content.body = "출발까지 \(toDeparture)분, 서두르세요."
            } else {
                content.body = "출발까지 \(toDeparture)분."
            }
            content.sound = nil
            content.threadIdentifier = "\(voicePrefix)\(route.id.uuidString)"
            content.interruptionLevel = .active

            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let id = "\(voicePrefix)\(route.id.uuidString)-\(Int(fireDate.timeIntervalSince1970))"
            requests.append(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        }
        return requests
    }

    /// 음성 안내 예약·표시된 알림 모두 지우기 (실시간 현황을 끌 때)
    static func removeVoice() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(voicePrefix) })
        await removeDeliveredVoice()
    }

    /// 이미 지나간 음성 안내 알림은 알림 센터에서 지워 깔끔하게 둔다.
    private static func removeDeliveredVoice() async {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        let ids = delivered.map(\.request.identifier).filter { $0.hasPrefix(voicePrefix) }
        if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
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
