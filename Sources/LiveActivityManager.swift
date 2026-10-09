import ActivityKit
import Foundation

/// 잠금화면 실시간 현황(Live Activity) 시작·갱신·종료.
/// 무료 Apple ID는 푸시를 못 쓰므로, 앱이 열려 있을 때 갱신한다.
/// 앱이 꺼져 있어도 다음 열차 4편의 카운트다운은 잠금화면에서 계속 흐른다.
@MainActor
enum LiveActivityManager {
    static var isSupported: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    static func isRunning(for route: Route) -> Bool {
        Activity<CommuteActivityAttributes>.activities.contains { $0.attributes.routeID == route.id.uuidString }
    }

    /// 자동 시작: 오늘 요일·시각 조건에 맞는 노선이 있으면 잠금화면 실시간 현황을 띄운다.
    /// (무료 Apple ID는 푸시로 시작할 수 없어서, 앱을 열거나 알림을 누를 때 실행된다)
    static func autoStartIfNeeded(routes: [Route], day: DayType, busText: (Route) -> String?) async {
        guard isSupported else { return }
        let now = Date()
        let today = RailSync.todayKey(now)
        let candidates = routes.filter { route in
            qualifies(route, now: now, day: day)
                && UserDefaults.standard.string(forKey: stoppedKey(route.id.uuidString)) != today
        }
        // 조건에 맞는 노선이 여러 개면 가장 늦게 시작하는 것(지금 시간대에 맞는 것)
        guard let route = candidates.max(by: { $0.liveAutoFrom < $1.liveAutoFrom }),
              !isRunning(for: route) else { return }
        try? await start(route: route, day: day, busText: busText(route), auto: true)
    }

    /// 자동 표시 조건: 지정한 요일(공휴일은 ‘휴일’) · 시간대 안 · 오늘 남은 열차가 있음
    static func qualifies(_ route: Route, now: Date, day: DayType) -> Bool {
        let minutes = TimeText.minutesOfDay(now)
        return route.liveAutoStart
            && route.liveAutoDays.contains(day)
            && minutes >= route.liveAutoFrom
            && minutes < route.liveAutoUntil
            && route.upcoming(from: now, day: day).contains { !$0.isTomorrow }
    }

    /// 단축어 ‘실시간 현황 켜기’ (iOS 17 LiveActivityIntent: 앱을 열지 않아도 시작 가능)
    static func startFromShortcut(force: Bool) async -> String {
        let routes = SharedData.loadRoutes() ?? []
        let now = Date()
        let day = DayOverride.effective(raw: SharedData.dayOverrideRaw, on: now)
        let route: Route?
        if force {
            let direction = CommuteDirection.suggested(for: now)
            route = routes.first { $0.direction == direction } ?? routes.first
        } else {
            route = routes.filter { qualifies($0, now: now, day: day) }.max { $0.liveAutoFrom < $1.liveAutoFrom }
        }
        guard let route else {
            return day == .holiday ? "오늘은 휴일이라 띄우지 않았어요." : "지금은 실시간 현황을 띄울 시간이 아니에요."
        }
        do {
            try await start(route: route, day: day, busText: nil, auto: !force)
            return "\(route.name) \(route.direction.title) 실시간 현황을 띄웠어요."
        } catch {
            return "실시간 현황을 띄우지 못했어요: \(error.localizedDescription)"
        }
    }

    /// 단축어 ‘실시간 현황 끄기’ (교통카드 태그 자동화 등). 끈 날은 자동으로 다시 켜지 않는다.
    static func endAllFromShortcut() async {
        for activity in Activity<CommuteActivityAttributes>.activities {
            UserDefaults.standard.set(RailSync.todayKey(), forKey: stoppedKey(activity.attributes.routeID))
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    static func start(route: Route, day: DayType, busText: String?, auto: Bool = false) async throws {
        UserDefaults.standard.removeObject(forKey: stoppedKey(route.id.uuidString))
        // 노선 하나만 표시: 기존 것은 모두 종료
        for activity in Activity<CommuteActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        let attributes = CommuteActivityAttributes(
            routeID: route.id.uuidString,
            routeName: route.name,
            stop: route.stop,
            destination: route.destination,
            walkMinutes: route.walkMinutes,
            opensKorail: route.tapOpensKorail,
            autoStarted: auto
        )
        let state = makeState(route: route, day: day, busText: busText)
        _ = try Activity.request(
            attributes: attributes,
            content: ActivityContent(state: state, staleDate: state.trains.first?.departure),
            pushType: nil
        )
    }

    /// 사용자가 직접 끈 날에는 자동으로 다시 켜지 않는다.
    private static func stoppedKey(_ routeID: String) -> String { "liveStopped-\(routeID)" }

    static func stop(route: Route) async {
        UserDefaults.standard.set(RailSync.todayKey(), forKey: stoppedKey(route.id.uuidString))
        for activity in Activity<CommuteActivityAttributes>.activities where activity.attributes.routeID == route.id.uuidString {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// 앱이 열려 있는 동안 주기적으로 호출: 지나간 열차를 빼고 버스 정보를 반영한다.
    static func updateAll(routes: [Route], day: DayType, busText: (Route) -> String?) async {
        for activity in Activity<CommuteActivityAttributes>.activities {
            guard let route = routes.first(where: { $0.id.uuidString == activity.attributes.routeID }) else {
                await activity.end(nil, dismissalPolicy: .immediate)
                continue
            }
            // 자동으로 띄운 것은 요일(공휴일)·시간대를 벗어나면 끈다.
            if activity.attributes.autoStarted ?? true, !qualifies(route, now: Date(), day: day) {
                await activity.end(nil, dismissalPolicy: .immediate)
                continue
            }
            let state = makeState(route: route, day: day, busText: busText(route))
            if state.trains.isEmpty {
                await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .default)
            } else {
                await activity.update(ActivityContent(state: state, staleDate: state.trains.first?.departure))
            }
        }
    }

    private static func makeState(route: Route, day: DayType, busText: String?) -> CommuteActivityAttributes.ContentState {
        let now = Date()
        return .init(
            trains: route.activityTrains(from: now, day: day),
            expressText: route.nextExpressText(from: now),
            busText: busText,
            seatText: route.seatText(on: now),
            updatedAt: now
        )
    }
}
