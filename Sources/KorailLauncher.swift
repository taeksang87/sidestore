import UIKit

/// 코레일톡 열기. 공식 URL 스킴이 공개돼 있지 않아서 후보를 차례로 시도하고,
/// 모두 실패하면 App Store의 코레일톡 페이지(‘열기’ 버튼)로 보낸다.
@MainActor
enum KorailLauncher {
    static let schemeStorage = "korailScheme"
    static let candidates = ["korailtalk://", "korailplus://", "korail://", "korailtalk4://"]
    static let appStoreURL = URL(string: "https://apps.apple.com/kr/app/id1000558562")!

    /// 열기에 성공한 방법을 돌려준다 (설정 화면 테스트용)
    @discardableResult
    static func open() async -> String {
        let custom = UserDefaults.standard.string(forKey: schemeStorage)?.trimmingCharacters(in: .whitespaces) ?? ""
        var schemes = candidates
        if !custom.isEmpty {
            schemes.insert(custom.contains("://") ? custom : custom + "://", at: 0)
        }
        for scheme in schemes {
            guard let url = URL(string: scheme) else { continue }
            if await UIApplication.shared.open(url) {
                return scheme
            }
        }
        _ = await UIApplication.shared.open(appStoreURL)
        return "App Store"
    }
}
