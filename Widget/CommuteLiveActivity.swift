import ActivityKit
import SwiftUI
import WidgetKit

struct CommuteLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CommuteActivityAttributes.self) { context in
            LiveActivityLockScreen(context: context)
                .widgetURL(context.attributes.tapURL)
                .activityBackgroundTint(Color(red: 0.06, green: 0.09, blue: 0.16).opacity(0.85))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let onboard = context.state.onboard
            let next = context.state.trains.first(where: { $0.departure > Date() }) ?? context.state.trains.first
            let walks = context.attributes.walkMinutes > 0
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(context.attributes.routeName, systemImage: "tram.fill")
                            .font(.caption)
                            .foregroundColor(.teal)
                        Text(next.map { TimeText.clock($0.departure) } ?? "--:--")
                            .font(.title2.bold())
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(walks ? "나가기까지" : "출발까지")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        if let next {
                            CountdownText(target: next.leaveBy)
                                .font(.title3.bold())
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 90, alignment: .trailing)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        if let next, let arrival = next.arrival {
                            Text("\(context.attributes.destination) \(next.arrivalIsExact ? "" : "약 ")\(TimeText.clock(arrival)) 도착")
                        }
                        Spacer()
                        if let seat = context.state.seatText {
                            Text(seat)
                                .foregroundColor(.yellow)
                        } else if let bus = context.state.busText {
                            Text(bus)
                                .foregroundColor(.green)
                        }
                    }
                    .font(.caption)
                }
            } compactLeading: {
                Image(systemName: "tram.fill")
                    .foregroundColor(.teal)
            } compactTrailing: {
                if let next {
                    CountdownText(target: onboard?.arrival ?? next.leaveBy)
                        .frame(maxWidth: 48)
                        .font(.caption.bold())
                }
            } minimal: {
                Image(systemName: "tram.fill")
                    .foregroundColor(.teal)
            }
            .widgetURL(context.attributes.tapURL)
        }
    }
}

struct LiveActivityLockScreen: View {
    let context: ActivityViewContext<CommuteActivityAttributes>

    var body: some View {
        let attributes = context.attributes
        let trains = context.state.trains
        let walks = attributes.walkMinutes > 0

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(attributes.destination.isEmpty ? "\(attributes.routeName) · \(attributes.stop)" : "\(attributes.routeName) · \(attributes.stop) → \(attributes.destination)",
                      systemImage: "tram.fill")
                    .font(.subheadline.bold())
                    .foregroundColor(.teal)
                Spacer()
                if context.isStale {
                    Text("앱을 열면 최신으로")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.5))
                }
            }

            if let seat = context.state.seatText {
                HStack {
                    Text(seat)
                        .font(.subheadline.bold())
                        .foregroundColor(.yellow)
                    Spacer()
                    if attributes.opensKorail {
                        Text("눌러서 코레일톡 ›")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            }

            if let onboard = context.state.onboard, let arrival = onboard.arrival {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("🚆 \(onboard.label ?? "열차") 탑승 중")
                            .font(.headline)
                        Text("\(attributes.destination) \(onboard.arrivalIsExact ? "" : "약 ")\(TimeText.clock(arrival)) 도착")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.65))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("도착까지")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.65))
                        CountdownText(target: arrival)
                            .font(.title.bold())
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 130, alignment: .trailing)
                    }
                }
            } else if let first = trains.first {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(TimeText.clock(first.departure))
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                            if let label = first.label {
                                Text(label)
                                    .font(.caption.bold())
                                    .foregroundColor(.orange)
                            }
                        }
                        if let arrival = first.arrival {
                            Text("\(attributes.destination) \(first.arrivalIsExact ? "" : "약 ")\(TimeText.clock(arrival)) 도착")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.65))
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(walks ? "\(TimeText.clock(first.leaveBy))까지 나가기" : "출발까지")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.65))
                        CountdownText(target: first.leaveBy)
                            .font(.title.bold())
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 130, alignment: .trailing)
                    }
                }

                if trains.count > 1 {
                    HStack(spacing: 12) {
                        Text("이후")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.5))
                        ForEach(trains.dropFirst(), id: \.self) { train in
                            VStack(alignment: .leading, spacing: 0) {
                                Text(TimeText.clock(train.departure))
                                    .font(.caption.bold())
                                CountdownText(target: train.leaveBy)
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.6))
                            }
                        }
                    }
                }
            } else {
                Text("오늘 운행이 끝났어요")
                    .font(.headline)
            }

            if context.state.expressText != nil || context.state.busText != nil {
                HStack {
                    if let express = context.state.expressText {
                        Text("🚄 \(express)")
                            .foregroundColor(.orange)
                            .lineLimit(1)
                    }
                    Spacer()
                    if let bus = context.state.busText {
                        Text(bus)
                            .foregroundColor(.green)
                    }
                }
                .font(.caption2)
            }
        }
        .foregroundColor(.white)
        .padding(14)
    }
}
