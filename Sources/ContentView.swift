import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: RouteStore
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(DayOverride.storageKey) private var dayOverrideRaw = ""
    @AppStorage(RailAPI.keyStorage) private var apiKey = ""
    @State private var direction = CommuteDirection.suggested()
    @State private var editing: Route?
    @State private var showingSettings = false

    private var day: DayType { DayOverride.effective(raw: dayOverrideRaw) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("구분", selection: $direction) {
                        ForEach(CommuteDirection.allCases) { d in
                            Text(d.title).tag(d)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                let routes = store.routes.filter { $0.direction == direction }

                if routes.isEmpty {
                    Section {
                        VStack(spacing: 8) {
                            Image(systemName: "clock.badge.questionmark")
                                .font(.largeTitle)
                                .foregroundColor(.secondary)
                            Text("등록된 \(direction.title) 노선이 없어요")
                                .font(.headline)
                            Text("오른쪽 위 + 버튼으로 시간표를 추가하세요.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    }
                }

                ForEach(routes) { route in
                    Section {
                        NavigationLink(value: route.id) {
                            RouteCard(route: route, day: day)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                store.delete(route)
                            } label: {
                                Label("삭제", systemImage: "trash")
                            }
                            Button {
                                editing = route
                            } label: {
                                Label("편집", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                    }
                }
            }
            .navigationTitle("\(direction.title) 시간표")
            .onAppear {
                // 추천 방향에 노선이 없으면 노선이 있는 쪽을 먼저 보여준다.
                if !store.routes.contains(where: { $0.direction == direction }),
                   let other = store.routes.first?.direction {
                    direction = other
                }
            }
            .navigationDestination(for: UUID.self) { id in
                TimetableView(routeID: id, initialDay: day)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    dayMenu
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        editing = Route(direction: direction)
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $editing) { route in
                RouteEditView(route: route)
                    .environmentObject(store)
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .task {
                await RailSync.autoSync(store: store, key: apiKey)
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    Task { await RailSync.autoSync(store: store, key: apiKey) }
                }
            }
            .onChange(of: apiKey) { _ in
                Task { await RailSync.autoSync(store: store, key: apiKey) }
            }
        }
    }

    private var dayMenu: some View {
        Menu {
            Picker("오늘 적용할 시간표", selection: Binding(
                get: { day },
                set: { dayOverrideRaw = DayOverride.raw(for: $0) }
            )) {
                ForEach(DayType.allCases) { d in
                    Text(d.title).tag(d)
                }
            }
            if DayOverride.isActive(raw: dayOverrideRaw) {
                Button("요일에 맞게 자동으로") {
                    dayOverrideRaw = ""
                }
            }
        } label: {
            Label(day.shortTitle, systemImage: DayOverride.isActive(raw: dayOverrideRaw) ? "calendar.badge.exclamationmark" : "calendar")
                .labelStyle(.titleAndIcon)
        }
    }
}

/// 동해선 위젯과 같은 구성: 다음 열차 · 직통열차 · 자전거 날씨
struct RouteCard: View {
    @EnvironmentObject private var weather: WeatherStore
    @EnvironmentObject private var bus: BusStore
    @EnvironmentObject private var store: RouteStore
    @AppStorage(RailAPI.keyStorage) private var apiKey = ""
    let route: Route
    let day: DayType

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(now: context.date)
        }
        .task(id: route.id) {
            if let lat = route.latitude, let lng = route.longitude {
                await weather.refreshIfNeeded(latitude: lat, longitude: lng)
            }
            // 화면에 보이는 동안 1분마다 버스 도착정보 갱신
            while !Task.isCancelled {
                await bus.refresh(route: route, key: apiKey, store: store, minInterval: 55)
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let upcoming = route.upcoming(from: now, day: day)
        let first = upcoming.first
        let leaveDate = now.addingTimeInterval(Double(max(0, first?.leaveIn ?? 0)))
        let forecast: WeatherSnapshot? = {
            guard let lat = route.latitude, let lng = route.longitude else { return nil }
            return weather.snapshot(latitude: lat, longitude: lng, at: leaveDate)
        }()

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: route.transport.symbol)
                    .foregroundColor(.teal)
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let forecast {
                    Text(forecast.summary)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if let first {
                mainBlock(first, later: Array(upcoming.dropFirst()))
            } else {
                Text("\(day.title) 시간표가 비어 있어요")
                    .foregroundColor(.secondary)
            }

            if let express = route.nextExpress(from: now), first?.isTomorrow != true {
                expressBlock(express)
            }

            if forecast != nil || !route.busRoutes.isEmpty {
                HStack {
                    if let forecast {
                        let bike = forecast.bikeStatus
                        Text("\(bike.icon) \(bike.text)")
                            .font(.caption.weight(.semibold))
                    }
                    Spacer()
                    if let next = bus.upcoming(for: route, now: now).first {
                        Text("🚌 \(next.arrival.routeNo)번 \(busTime(next.remaining))")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundColor(.green)
                    } else if !route.busRoutes.isEmpty {
                        Text("🚌 눌러서 경유버스 보기")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func busTime(_ seconds: Int) -> String {
        seconds < 60 ? "곧 도착" : "\(seconds / 60)분 후"
    }

    private var title: String {
        if route.destination.isEmpty {
            return route.stop.isEmpty ? route.name : "\(route.name) · \(route.stop)"
        }
        return "\(route.name) · \(route.stop) → \(route.destination)"
    }

    private func mainBlock(_ first: Departure, later: [Departure]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(first.isTomorrow ? "내일 \(TimeText.clock(first.minutes))" : TimeText.clock(first.minutes))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(.teal)
                    if let arrival = route.arrivalEstimate(for: first) {
                        Text("\(route.destination.isEmpty ? "도착" : route.destination + " 도착") \(arrival.exact ? "" : "약 ")\(TimeText.clock(arrival.minutes))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                actionBlock(first)
            }

            if !later.isEmpty {
                HStack(spacing: 6) {
                    Text("이후")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    ForEach(later, id: \.minutes) { d in
                        Text(d.isTomorrow ? "내일 \(TimeText.clock(d.minutes))" : TimeText.clock(d.minutes))
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                }
            }
        }
        .padding(12)
        .background(Color.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func actionBlock(_ first: Departure) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            if first.isTomorrow {
                Text("오늘 운행 종료")
                    .font(.subheadline.bold())
                Text("\(TimeText.clock(first.minutes - route.walkMinutes)) 출발")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if first.leaveIn <= 0 {
                Text(route.walkMinutes > 0 ? "⚡ 서둘러야 함" : "곧 출발")
                    .font(.subheadline.bold())
                    .foregroundColor(.red)
                Text("열차 출발까지 \(TimeText.countdown(first.secondsUntil))")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            } else {
                Text(TimeText.countdown(first.leaveIn))
                    .font(.title3.bold().monospacedDigit())
                    .foregroundColor(first.leaveIn < 300 ? .orange : .primary)
                Text(route.walkMinutes > 0 ? "뒤 출발 · \(TimeText.clock(first.minutes - route.walkMinutes))까지" : "남음")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func expressBlock(_ express: ExpressTrain) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("🚄 \(express.type) \(express.number)")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.orange)
                    Text("\(TimeText.clock(express.departure)) → \(express.station) \(TimeText.clock(express.arrival))")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                }
                Spacer()
                Text(TimeText.won(express.price))
                    .font(.subheadline.bold())
            }
            if let finalArrival = route.transferArrival(for: express) {
                HStack {
                    Text("🔄 환승 \(route.transferMinutes)분 · \(route.destination) 도착 \(TimeText.clock(finalArrival))")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.purple)
                    Spacer()
                    if route.transferFare > 0 {
                        Text("+\(TimeText.won(route.transferFare))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
    }
}
