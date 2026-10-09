import SwiftUI
import WidgetKit

struct CommuteEntry: TimelineEntry {
    let date: Date
    let route: Route?
    let day: DayType
    let trains: [CommuteActivityAttributes.Train]
    let express: String?
}

struct CommuteProvider: TimelineProvider {
    func placeholder(in context: Context) -> CommuteEntry {
        entry(at: Date(), routes: Route.samples)
    }

    func getSnapshot(in context: Context, completion: @escaping (CommuteEntry) -> Void) {
        completion(entry(at: Date(), routes: loadRoutes()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CommuteEntry>) -> Void) {
        let now = Date()
        let routes = loadRoutes()

        // 나가야 할 시각·열차 출발 시각마다 화면을 바꿔 다음 열차가 항상 맞게 보이도록 한다.
        var dates: Set<Date> = [now]
        if let route = pickRoute(routes, at: now) {
            let day = DayOverride.effective(raw: SharedData.dayOverrideRaw, on: now)
            for train in route.activityTrains(from: now, day: day, limit: 12) {
                dates.insert(train.leaveBy)
                dates.insert(train.departure.addingTimeInterval(1))
            }
        }
        let horizon = now.addingTimeInterval(6 * 3600)
        let sorted = dates.filter { $0 >= now && $0 <= horizon }.sorted().prefix(30)
        let entries = sorted.map { entry(at: $0, routes: routes) }

        let reload = min(max(entries.last?.date ?? now, now.addingTimeInterval(15 * 60)), now.addingTimeInterval(3 * 3600))
        completion(Timeline(entries: entries, policy: .after(reload)))
    }

    private func loadRoutes() -> [Route] {
        SharedData.loadRoutes() ?? Route.samples
    }

    /// 오전엔 출근, 오후엔 퇴근 노선. 해당 방향이 없으면 첫 노선
    private func pickRoute(_ routes: [Route], at date: Date) -> Route? {
        let direction = CommuteDirection.suggested(for: date)
        return routes.first { $0.direction == direction } ?? routes.first
    }

    private func entry(at date: Date, routes: [Route]) -> CommuteEntry {
        let day = DayOverride.effective(raw: SharedData.dayOverrideRaw, on: date)
        guard let route = pickRoute(routes, at: date) else {
            return CommuteEntry(date: date, route: nil, day: day, trains: [], express: nil)
        }
        return CommuteEntry(
            date: date,
            route: route,
            day: day,
            trains: route.activityTrains(from: date, day: day),
            express: route.nextExpressText(from: date)
        )
    }
}

struct CommuteWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CommuteWidget", provider: CommuteProvider()) { entry in
            CommuteWidgetView(entry: entry)
        }
        .configurationDisplayName("출퇴근 시간표")
        .description("다음 열차와 출발까지 남은 시간")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline, .accessoryCircular])
    }
}

struct CommuteWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CommuteEntry

    var body: some View {
        content
            .widgetURL(entry.route.flatMap { route in
                URL(string: route.tapOpensKorail ? "commutetimer://korail" : "commutetimer://route/\(route.id.uuidString)")
            })
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryInline:
            inline.widgetBackground(.clear)
        case .accessoryCircular:
            circular.widgetBackground(.clear)
        case .accessoryRectangular:
            rectangular.widgetBackground(.clear)
        case .systemMedium:
            medium.widgetBackground(Color(red: 0.08, green: 0.13, blue: 0.22))
        default:
            small.widgetBackground(Color(red: 0.08, green: 0.13, blue: 0.22))
        }
    }

    private var first: CommuteActivityAttributes.Train? { entry.trains.first }
    private var name: String { entry.route?.name ?? "출퇴근" }
    private var walks: Bool { (entry.route?.walkMinutes ?? 0) > 0 }

    private var sectionText: String {
        guard let route = entry.route, !route.destination.isEmpty else { return "" }
        return " · \(route.stop) → \(route.destination)"
    }

    private func arrivalText(_ train: CommuteActivityAttributes.Train) -> String? {
        guard let arrival = train.arrival else { return nil }
        let destination = entry.route?.destination ?? ""
        return "\(destination.isEmpty ? "도착" : destination) \(train.arrivalIsExact ? "" : "약 ")\(TimeText.clock(arrival))"
    }

    // MARK: 잠금화면

    private var inline: some View {
        Group {
            if let first {
                Text("🚆 \(TimeText.clock(first.departure)) · \(TimeText.clock(first.leaveBy))까지 출발")
            } else {
                Text("🚆 \(name) 오늘 운행 종료")
            }
        }
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: "tram.fill")
                    .font(.system(size: 11))
                Text(first.map { TimeText.clock($0.departure) } ?? "--:--")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.6)
            }
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let first {
                Text("🚆 \(TimeText.clock(first.departure)) \(name)")
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 3) {
                    Text(first.leaveBy > entry.date ? (walks ? "출발까지" : "남은 시간") : "열차까지")
                    CountdownText(target: first.leaveBy > entry.date ? first.leaveBy : first.departure)
                }
                .font(.caption.weight(.semibold))
                if let arrival = arrivalText(first) {
                    Text(arrival)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                Text("🚆 \(name)")
                    .font(.headline)
                Text("오늘 운행이 끝났어요")
                    .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 홈 화면

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "tram.fill")
                Text(name)
                    .lineLimit(1)
            }
            .font(.caption.weight(.semibold))
            .foregroundColor(.white.opacity(0.8))

            if let first {
                Text(TimeText.clock(first.departure))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundColor(.teal)
                leaveCountdown(first)
                    .font(.title3.bold())
                    .foregroundColor(.white)
                if let arrival = arrivalText(first) {
                    Text(arrival)
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.6))
                }
            } else {
                Spacer()
                Text("오늘 운행 종료")
                    .font(.headline)
                    .foregroundColor(.white)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("🚆 \(name)\(sectionText)")
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Spacer()
                Text(entry.day.shortTitle)
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.6))
            }
            .foregroundColor(.white)

            if let seat = entry.route?.seatText(on: entry.date) {
                Text(seat)
                    .font(.caption.bold())
                    .foregroundColor(.yellow)
            }

            if let first {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(TimeText.clock(first.departure))
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundColor(.teal)
                        if let arrival = arrivalText(first) {
                            Text(arrival)
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.6))
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        leaveCountdown(first)
                            .font(.title3.bold())
                            .foregroundColor(first.leaveBy > entry.date ? .white : .red)
                            .multilineTextAlignment(.trailing)
                        Text(walks ? "\(TimeText.clock(first.leaveBy))까지 출발" : "출발까지")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
                .padding(8)
                .background(Color.teal.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))

                if entry.trains.count > 1 {
                    HStack(spacing: 4) {
                        Text("이후")
                            .foregroundColor(.white.opacity(0.5))
                        Text(entry.trains.dropFirst().map { TimeText.clock($0.departure) }.joined(separator: " · "))
                            .foregroundColor(.white.opacity(0.85))
                    }
                    .font(.caption.weight(.semibold))
                }
                if let express = entry.express {
                    Text("🚄 \(express)")
                        .font(.caption2)
                        .foregroundColor(.orange)
                        .lineLimit(1)
                }
            } else {
                Spacer()
                Text("오늘 운행이 끝났어요")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func leaveCountdown(_ train: CommuteActivityAttributes.Train) -> some View {
        if train.leaveBy > entry.date {
            CountdownText(target: train.leaveBy)
        } else {
            HStack(spacing: 2) {
                Text("⚡")
                CountdownText(target: train.departure)
            }
        }
    }
}
