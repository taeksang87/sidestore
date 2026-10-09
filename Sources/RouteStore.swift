import Foundation
import WidgetKit

final class RouteStore: ObservableObject {
    @Published var routes: [Route] = [] {
        didSet { save() }
    }

    init() {
        // 위젯과 공유하는 App Group 저장소를 먼저 보고, 예전 버전이 앱 문서 폴더에 저장한 데이터가 있으면 옮겨 온다.
        if let shared = SharedData.loadRoutes() {
            routes = shared.map(Self.migrate)
        } else if let data = try? Data(contentsOf: SharedData.localRoutesURL),
                  let decoded = try? JSONDecoder().decode([Route].self, from: data) {
            routes = decoded.map(Self.migrate)
            save()
        } else {
            routes = Route.samples
            save()
        }
        applyOneTimeUpdates()
    }

    /// 버전 업데이트 때 한 번만 적용하는 기본값 변경
    private func applyOneTimeUpdates() {
        let defaults = UserDefaults.standard
        let key = "oneTimeUpdate.v3"
        guard !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)

        var updated = routes
        // 퇴근 동해선: 평일 15시부터 잠금화면 실시간 현황
        for index in updated.indices where updated[index].name == "동해선" && updated[index].direction == .toHome {
            updated[index].liveAutoStart = true
        }
        // 출근 동해선(센텀 → 태화강 06:11) 추가
        if !updated.contains(where: { $0.direction == .toWork }) {
            updated.insert(Route.commuteToWorkSample, at: 0)
        }
        if updated != routes { routes = updated }
    }

    /// 첫 버전에서 만든 동해선 기본 노선에 철도 API 연동을 켜 준다.
    private static func migrate(_ route: Route) -> Route {
        var route = route
        if route.name == "동해선", route.stop == "태화강", route.timetableSyncedAt == nil, route.transferStation.isEmpty {
            route.autoSync = true
            route.transferStation = "신해운대"
        }
        return route
    }

    func route(id: UUID) -> Route? {
        routes.first { $0.id == id }
    }

    func contains(_ route: Route) -> Bool {
        routes.contains { $0.id == route.id }
    }

    func upsert(_ route: Route) {
        if let index = routes.firstIndex(where: { $0.id == route.id }) {
            routes[index] = route
        } else {
            routes.append(route)
        }
    }

    func delete(_ route: Route) {
        routes.removeAll { $0.id == route.id }
    }

    private func save() {
        do {
            try SharedData.saveRoutes(routes)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            print("저장 실패: \(error)")
        }
    }
}
