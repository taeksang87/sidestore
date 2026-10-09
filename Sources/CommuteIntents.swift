import ActivityKit
import AppIntents

/// 단축어 ‘출퇴근 실시간 현황 켜기’
/// 자동화(예: 평일 15:00)에 넣으면 앱을 열지 않아도 잠금화면에 띄운다. 공휴일·설정 밖 시간대에는 띄우지 않는다.
struct StartCommuteActivityIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "출퇴근 실시간 현황 켜기"
    static var description = IntentDescription("다음 열차 카운트다운을 잠금화면에 띄워요. 공휴일이나 노선에서 정한 요일·시간대가 아니면 띄우지 않아요.")

    @Parameter(title: "요일·시간 조건 무시", default: false)
    var force: Bool

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = await LiveActivityManager.startFromShortcut(force: force)
        return .result(dialog: "\(message)")
    }
}

/// 단축어 ‘출퇴근 실시간 현황 끄기’
/// 지갑 ‘거래’ 자동화(교통카드 태그)나 위치 도착 자동화에 넣어서 쓴다.
struct EndCommuteActivityIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "출퇴근 실시간 현황 끄기"
    static var description = IntentDescription("잠금화면의 출퇴근 실시간 현황을 끄고, 오늘은 자동으로 다시 켜지 않아요.")

    func perform() async throws -> some IntentResult {
        await LiveActivityManager.endAllFromShortcut()
        return .result()
    }
}

struct CommuteShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartCommuteActivityIntent(),
            phrases: ["\(.applicationName) 실시간 현황 켜기"],
            shortTitle: "실시간 현황 켜기",
            systemImageName: "tram.fill"
        )
        AppShortcut(
            intent: EndCommuteActivityIntent(),
            phrases: ["\(.applicationName) 실시간 현황 끄기"],
            shortTitle: "실시간 현황 끄기",
            systemImageName: "lock.slash"
        )
    }
}
