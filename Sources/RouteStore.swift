import Foundation

final class RouteStore: ObservableObject {
    @Published var routes: [Route] = [] {
        didSet { save() }
    }

    private let fileURL: URL

    init() {
        fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("routes.json")

        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([Route].self, from: data) {
            routes = decoded
        } else {
            routes = Route.samples
        }
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
            let data = try JSONEncoder().encode(routes)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("저장 실패: \(error)")
        }
    }
}
