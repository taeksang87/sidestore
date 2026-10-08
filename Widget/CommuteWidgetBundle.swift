import SwiftUI
import WidgetKit

@main
struct CommuteWidgetBundle: WidgetBundle {
    var body: some Widget {
        CommuteWidget()
        CommuteLiveActivity()
    }
}

extension View {
    /// iOS 17부터는 containerBackground를 써야 위젯 배경이 제대로 나온다.
    @ViewBuilder
    func widgetBackground(_ color: Color) -> some View {
        if #available(iOS 17.0, *) {
            containerBackground(color, for: .widget)
        } else {
            background(color)
        }
    }
}

/// 남은 시간 카운트다운. 지난 시각이면 0:00에서 멈춘다.
struct CountdownText: View {
    let target: Date

    var body: some View {
        let now = Date()
        Text(timerInterval: now...max(target, now), countsDown: true)
            .monospacedDigit()
    }
}
