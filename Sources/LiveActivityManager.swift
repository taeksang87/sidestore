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

    static func start(route: Route, day: DayType, busText: String?) async throws {
        // 노선 하나만 표시: 기존 것은 모두 종료
        for activity in Activity<CommuteActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        let attributes = CommuteActivityAttributes(
            routeID: route.id.uuidString,
            routeName: route.name,
            stop: route.stop,
            destination: route.destination,
            walkMinutes: route.walkMinutes
        )
        let state = makeState(route: route, day: day, busText: busText)
        _ = try Activity.request(
            attributes: attributes,
            content: ActivityContent(state: state, staleDate: state.trains.first?.departure),
            pushType: nil
        )
    }

    static func stop(route: Route) async {
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
            updatedAt: now
        )
    }
}
