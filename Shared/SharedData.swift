import Foundation

/// 앱과 위젯이 같이 쓰는 저장소 (App Group).
///
/// SideStore가 무료 Apple ID로 다시 서명하면 App Group 이름이 바뀐다(예: group.app.commutetimer.ABCDE12345).
/// 바뀐 실제 이름은 Info.plist의 ALTAppGroups나 설치된 프로비저닝 프로파일에서 찾는다.
enum AppGroup {
    static let configured = "group.app.commutetimer"

    static let identifier: String? = {
        var candidates: [String] = []
        for bundle in [Bundle.main, containingAppBundle].compactMap({ $0 }) {
            if let groups = bundle.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] {
                candidates += groups
            }
        }
        candidates += provisioningGroups()
        candidates.append(configured)

        // 실제로 열리는 그룹만 쓴다.
        return candidates.first { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil }
    }()

    static var containerURL: URL? {
        identifier.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    }

    /// 위젯(.appex)이면 그걸 담고 있는 앱 번들
    private static var containingAppBundle: Bundle? {
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "appex" else { return nil }
        return Bundle(url: url.deletingLastPathComponent().deletingLastPathComponent())
    }

    private static func provisioningGroups() -> [String] {
        var urls: [URL] = []
        for bundle in [Bundle.main, containingAppBundle].compactMap({ $0 }) {
            if let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision") { urls.append(url) }
        }
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let start = data.range(of: Data("<?xml".utf8)),
                  let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
                  let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
                  let entitlements = plist["Entitlements"] as? [String: Any],
                  let groups = entitlements["com.apple.security.application-groups"] as? [String]
            else { continue }
            return groups
        }
        return []
    }
}

enum SharedData {
    private static let dayOverrideKey = "sharedDayOverride"

    static var defaults: UserDefaults {
        AppGroup.identifier.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    /// 노선 저장 파일. App Group을 못 열면 앱 자체 문서 폴더를 쓴다.
    static var routesURL: URL {
        if let container = AppGroup.containerURL {
            return container.appendingPathComponent("routes.json")
        }
        return localRoutesURL
    }

    static var localRoutesURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("routes.json")
    }

    static var isShared: Bool { AppGroup.containerURL != nil }

    static func loadRoutes() -> [Route]? {
        guard let data = try? Data(contentsOf: routesURL) else { return nil }
        return try? JSONDecoder().decode([Route].self, from: data)
    }

    static func saveRoutes(_ routes: [Route]) throws {
        let data = try JSONEncoder().encode(routes)
        try data.write(to: routesURL, options: .atomic)
    }

    /// 공휴일 수동 지정 (위젯도 같은 요일 시간표를 쓰도록)
    static var dayOverrideRaw: String {
        get { defaults.string(forKey: dayOverrideKey) ?? "" }
        set { defaults.set(newValue, forKey: dayOverrideKey) }
    }
}
