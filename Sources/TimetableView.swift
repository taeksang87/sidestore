import SwiftUI

struct TimetableView: View {
    @EnvironmentObject private var store: RouteStore
    @Environment(\.openURL) private var openURL
    @AppStorage(DayOverride.storageKey) private var dayOverrideRaw = ""
    let routeID: UUID
    @State private var day: DayType
    @State private var editing: Route?
    @State private var openingMap = false
    @State private var showNaverMissing = false

    init(routeID: UUID, initialDay: DayType) {
        self.routeID = routeID
        _day = State(initialValue: initialDay)
    }

    var body: some View {
        if let route = store.route(id: routeID) {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                timetable(route: route, now: context.date)
            }
            .navigationTitle(route.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("편집") { editing = route }
            }
            .sheet(item: $editing) { route in
                RouteEditView(route: route)
                    .environmentObject(store)
            }
            .alert("네이버지도 앱을 열 수 없어요", isPresented: $showNaverMissing) {
                Button("확인", role: .cancel) {}
            } message: {
                Text("App Store에서 네이버지도를 설치한 뒤 다시 시도하세요.")
            }
        } else {
            Text("삭제된 노선이에요")
                .foregroundColor(.secondary)
        }
    }

    private func timetable(route: Route, now: Date) -> some View {
        let times = route.times(for: day)
        let isToday = day == DayOverride.effective(raw: dayOverrideRaw, on: now)
        let nowMinutes = TimeText.minutesOfDay(now)
        let next = isToday ? times.first(where: { $0 >= nowMinutes }) : nil
        let grouped = Dictionary(grouping: times) { $0 / 60 }

        return List {
            if !route.busRoutes.isEmpty {
                busSection(route)
            }

            Section {
                Picker("요일", selection: $day) {
                    ForEach(DayType.allCases) { d in
                        Text(d.title).tag(d)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            Section {
                if !route.stop.isEmpty {
                    LabeledContent("구간", value: route.destination.isEmpty ? route.stop : "\(route.stop) → \(route.destination)")
                }
                LabeledContent("구분", value: "\(route.direction.title) · \(route.transport.title)")
                if route.walkMinutes > 0 {
                    LabeledContent("역까지 이동", value: "\(route.walkMinutes)분")
                }
                if route.rideMinutes > 0 {
                    LabeledContent("탑승 시간", value: "\(route.rideMinutes)분")
                }
                if let first = times.first, let last = times.last {
                    LabeledContent("첫차 / 막차", value: "\(TimeText.clock(first)) / \(TimeText.clock(last))")
                }
            }

            if times.isEmpty {
                Section {
                    Text("\(day.title) 시간표가 비어 있어요. 오른쪽 위 ‘편집’에서 추가하세요.")
                        .foregroundColor(.secondary)
                }
            } else {
                Section("\(day.title) · 하루 \(times.count)회") {
                    ForEach(grouped.keys.sorted(), id: \.self) { hour in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(String(format: "%02d", hour))
                                .font(.headline.monospacedDigit())
                                .frame(width: 30, alignment: .leading)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 34), spacing: 6)], alignment: .leading, spacing: 6) {
                                ForEach(grouped[hour, default: []], id: \.self) { m in
                                    minuteCell(m, isNext: m == next, isPast: isToday && m < nowMinutes)
                                }
                            }
                        }
                    }
                }
            }

            if !route.expresses.isEmpty {
                Section("직통열차") {
                    ForEach(route.expresses) { train in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("\(train.type) \(train.number)")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(.orange)
                                Spacer()
                                Text(TimeText.won(train.price))
                                    .font(.subheadline)
                            }
                            Text("\(TimeText.clock(train.departure)) → \(train.station) \(TimeText.clock(train.arrival))")
                                .font(.body.monospacedDigit())
                                .foregroundColor(isToday && train.departure < nowMinutes ? .secondary : .primary)
                            if let finalArrival = route.transferArrival(for: train) {
                                Text("환승 \(route.transferMinutes)분 → \(route.destination) \(TimeText.clock(finalArrival)) (+\(TimeText.won(route.transferFare)))")
                                    .font(.caption)
                                    .foregroundColor(.purple)
                            }
                        }
                    }
                }
            }
        }
    }

    private func busSection(_ route: Route) -> some View {
        // 앞 두 자리 기준으로 묶기 (21x, 41x, 71x …)
        let groups = Dictionary(grouping: route.busRoutes) { String($0.prefix(2)) }
        let prefixes = groups.keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
        let origin = route.busOrigin.isEmpty ? "출발지" : route.busOrigin

        return Section {
            ForEach(prefixes, id: \.self) { prefix in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("\(prefix)x")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 30, alignment: .leading)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 46), spacing: 8)], alignment: .leading, spacing: 6) {
                        ForEach(groups[prefix, default: []], id: \.self) { number in
                            Text(number)
                                .font(.body.bold().monospacedDigit())
                        }
                    }
                }
            }
            if route.hasCoordinate {
                Button {
                    openNaverMap(route)
                } label: {
                    HStack {
                        Label("네이버지도에서 대중교통 길찾기", systemImage: "map")
                        Spacer()
                        if openingMap { ProgressView() }
                    }
                }
                .disabled(openingMap)
            }
        } header: {
            Text("🚌 \(origin) ⇄ \(NaverMap.stationName(route.stop)) 경유 버스")
        }
    }

    private func openNaverMap(_ route: Route) {
        openingMap = true
        Task {
            let url = await NaverMap.transitRouteURL(for: route)
            openingMap = false
            guard let url else { return }
            openURL(url) { accepted in
                if !accepted { showNaverMissing = true }
            }
        }
    }

    private func minuteCell(_ minutes: Int, isNext: Bool, isPast: Bool) -> some View {
        Text(String(format: "%02d", minutes % 60))
            .font(.body.monospacedDigit())
            .fontWeight(isNext ? .bold : .regular)
            .foregroundColor(isNext ? .white : (isPast ? .secondary : .primary))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(isNext ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    }
}
