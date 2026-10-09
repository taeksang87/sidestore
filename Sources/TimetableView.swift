import SwiftUI

struct TimetableView: View {
    @EnvironmentObject private var store: RouteStore
    @EnvironmentObject private var bus: BusStore
    @Environment(\.openURL) private var openURL
    @AppStorage(DayOverride.storageKey) private var dayOverrideRaw = ""
    let routeID: UUID
    @State private var day: DayType
    @State private var editing: Route?
    @State private var openingMap = false
    @State private var showNaverMissing = false
    @AppStorage(RailAPI.keyStorage) private var apiKey = ""
    @State private var syncing = false
    @State private var syncMessages: [String] = []
    @State private var syncFailed = false
    @State private var liveRunning = false
    @State private var liveError: String?
    @State private var notifyDenied = false
    @State private var pendingCount = 0

    init(routeID: UUID, initialDay: DayType) {
        self.routeID = routeID
        _day = State(initialValue: initialDay)
    }

    var body: some View {
        if let route = store.route(id: routeID) {
            TimelineView(.periodic(from: .now, by: 5)) { context in
                timetable(route: route, now: context.date)
            }
            .task(id: routeID) {
                // 이 화면이 떠 있는 동안 30초마다 버스 도착정보 갱신
                while !Task.isCancelled {
                    if let current = store.route(id: routeID) {
                        liveRunning = LiveActivityManager.isRunning(for: current)
                        pendingCount = await NotificationScheduler.pendingCount(for: current)
                        await bus.refreshAll(route: current, key: apiKey, store: store, minInterval: 25)
                    }
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                }
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
            if route.autoSync || !apiKey.isEmpty {
                syncSection(route)
            }

            alertsSection(route)

            if !route.busRoutes.isEmpty {
                liveBusSection(route, now: now)
                busSection(route)
            }

            if route.hasBus(.connect) {
                connectSection(route, now: now)
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

    private func alertsSection(_ route: Route) -> some View {
        let binding = Binding<Route>(
            get: { store.route(id: route.id) ?? route },
            set: { store.upsert($0) }
        )
        let current = binding.wrappedValue

        return Section {
            Button {
                toggleLiveActivity(current)
            } label: {
                Label(liveRunning ? "잠금화면 실시간 표시 끄기" : "잠금화면에 실시간 표시",
                      systemImage: liveRunning ? "lock.slash" : "lock.iphone")
            }
            if !LiveActivityManager.isSupported {
                Text("아이폰 설정 > 출퇴근 > ‘실시간 현황’을 켜 주세요.")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            if let liveError {
                Text(liveError)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Toggle("자동으로 잠금화면 표시", isOn: Binding(
                get: { current.liveAutoStart },
                set: { on in
                    binding.wrappedValue.liveAutoStart = on
                    // 시작 시각에 ‘탭하면 시작’ 알림을 보내려면 알림 권한이 필요하다.
                    if on { Task { _ = await NotificationScheduler.requestAuthorization() } }
                }
            ))
            if current.liveAutoStart {
                DatePicker("이 시각부터", selection: minutesBinding(binding.liveAutoFrom), displayedComponents: .hourAndMinute)
                DatePicker("이 시각까지", selection: minutesBinding(binding.liveAutoUntil), displayedComponents: .hourAndMinute)
                dayChips(binding.liveAutoDays)
            }
            Toggle("잠금화면 누르면 코레일톡 열기", isOn: binding.tapOpensKorail)
            if current.tapOpensKorail {
                Button {
                    Task { await KorailLauncher.open() }
                } label: {
                    Label("지금 코레일톡 열기", systemImage: "ticket")
                }
            }

            Toggle("출발 알림", isOn: Binding(
                get: { current.notifyEnabled },
                set: { on in
                    if on {
                        Task {
                            if await NotificationScheduler.requestAuthorization() {
                                var updated = binding.wrappedValue
                                updated.notifyEnabled = true
                                store.upsert(updated)
                                notifyDenied = false
                            } else {
                                notifyDenied = true
                            }
                        }
                    } else {
                        binding.wrappedValue.notifyEnabled = false
                    }
                }
            ))

            if current.notifyEnabled {
                Stepper("나가기 \(current.notifyLead)분 전에 알림", value: binding.notifyLead, in: 0...30)
                DatePicker("이 시각 열차부터", selection: minutesBinding(binding.notifyFrom), displayedComponents: .hourAndMinute)
                DatePicker("이 시각 열차까지", selection: minutesBinding(binding.notifyTo), displayedComponents: .hourAndMinute)
                HStack(spacing: 8) {
                    ForEach(DayType.allCases) { d in
                        let on = current.notifyDays.contains(d)
                        Button {
                            var updated = binding.wrappedValue
                            if on {
                                updated.notifyDays.removeAll { $0 == d }
                            } else {
                                updated.notifyDays.append(d)
                            }
                            store.upsert(updated)
                        } label: {
                            Text(d.shortTitle)
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(on ? Color.accentColor : Color.secondary.opacity(0.15), in: Capsule())
                                .foregroundColor(on ? .white : .primary)
                        }
                        .buttonStyle(.borderless)
                    }
                    Spacer()
                    Text("예약 \(pendingCount)개")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            if notifyDenied {
                Text("알림 권한이 꺼져 있어요. 아이폰 설정 > 출퇴근 > 알림에서 허용해 주세요.")
                    .font(.caption)
                    .foregroundColor(.red)
            }
        } header: {
            Text("알림·잠금화면")
        } footer: {
            Text("자동 표시: 정한 요일·시간대에 ‘탭하면 시작’ 알림이 오고, 앱을 열면 바로 잠금화면에 떠요. 공휴일은 ‘휴일’로 봐서 평일만 켜 두면 뜨지 않아요. 시간대가 지나면 자동으로 꺼지고, 직접 끈 날은 다시 켜지지 않아요. 단축어 자동화로 앱을 열지 않고 켜고 끌 수도 있어요 (⚙︎ 설정 참고).\n잠금화면 표시는 앱을 열 때마다 최신으로 바뀌고, 앱이 꺼져 있어도 다음 열차 4편의 카운트다운은 계속 흘러가요. 출발 알림은 앱을 열 때마다 앞으로 7일 치를 다시 예약해요.")
        }
    }

    private func dayChips(_ days: Binding<[DayType]>) -> some View {
        HStack(spacing: 8) {
            ForEach(DayType.allCases) { d in
                let on = days.wrappedValue.contains(d)
                Button {
                    if on {
                        days.wrappedValue.removeAll { $0 == d }
                    } else {
                        days.wrappedValue.append(d)
                    }
                } label: {
                    Text(d.shortTitle)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(on ? Color.accentColor : Color.secondary.opacity(0.15), in: Capsule())
                        .foregroundColor(on ? .white : .primary)
                }
                .buttonStyle(.borderless)
            }
            Spacer()
        }
    }

    private func minutesBinding(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(byAdding: .minute, value: minutes.wrappedValue, to: Calendar.current.startOfDay(for: Date())) ?? Date()
            },
            set: { minutes.wrappedValue = TimeText.minutesOfDay($0) }
        )
    }

    private func toggleLiveActivity(_ route: Route) {
        Task {
            if LiveActivityManager.isRunning(for: route) {
                await LiveActivityManager.stop(route: route)
                liveRunning = false
            } else {
                do {
                    try await LiveActivityManager.start(
                        route: route,
                        day: DayOverride.effective(raw: dayOverrideRaw),
                        busText: bus.summary(for: route)
                    )
                    liveRunning = true
                    liveError = nil
                } catch {
                    liveError = "잠금화면 표시를 시작하지 못했어요: \(error.localizedDescription)"
                }
            }
        }
    }

    private func syncSection(_ route: Route) -> some View {
        Section {
            Button {
                runSync(route)
            } label: {
                HStack {
                    Label("철도 API로 지금 업데이트", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    if syncing { ProgressView() }
                }
            }
            .disabled(syncing || apiKey.isEmpty)

            if apiKey.isEmpty {
                Text("홈 화면 오른쪽 위 ⚙︎ 설정에서 공공데이터포털 인증키를 입력하세요.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            ForEach(syncMessages, id: \.self) { message in
                Text(message)
                    .font(.caption)
                    .foregroundColor(syncFailed ? .red : .secondary)
            }
        } header: {
            Text("철도 API 연동")
        } footer: {
            VStack(alignment: .leading, spacing: 2) {
                if let synced = route.timetableSyncedAt {
                    Text("시간표 업데이트: \(synced.formatted(date: .abbreviated, time: .shortened))")
                }
                if !route.expressSyncedDay.isEmpty {
                    Text(route.expressSyncedDay == RailSync.todayKey() ? "직통열차: 오늘 운행 정보" : "직통열차: \(route.expressSyncedDay) 기준")
                }
            }
        }
    }

    private func runSync(_ route: Route) {
        syncing = true
        syncMessages = []
        Task {
            do {
                let result = try await RailSync.sync(route, key: apiKey, timetable: true, express: true)
                store.upsert(result.route)
                syncMessages = result.messages
                syncFailed = false
            } catch {
                syncMessages = [error.localizedDescription]
                syncFailed = true
            }
            syncing = false
        }
    }

    /// 내린 역에서 갈아탈 버스 실시간 (열차 도착 + 환승 시간 이후 탈 수 있는지 표시)
    private func connectSection(_ route: Route, now: Date) -> some View {
        let state = bus.state(for: route, kind: .connect)
        let items = bus.upcoming(for: route, kind: .connect, now: now)
        let train = route.connectionTrain(at: now, day: DayOverride.effective(raw: dayOverrideRaw, on: now))
        let ready = train?.arrival?.addingTimeInterval(Double(route.connectTransferMinutes * 60))

        return Section {
            if let train, let arrival = train.arrival {
                LabeledContent("\(train.label ?? "열차") \(TimeText.clock(train.departure))",
                               value: "\(route.connectStopName) \(TimeText.clock(arrival)) 도착 → 정류장 \(TimeText.clock(ready ?? arrival))")
                    .font(.caption)
            }
            if apiKey.isEmpty {
                Text("홈 화면 ⚙︎ 설정에서 인증키를 넣으면 실시간 버스를 볼 수 있어요.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if let error = state?.error {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            } else if state?.fetchedAt == nil {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("불러오는 중…")
                        .foregroundColor(.secondary)
                }
            } else if items.isEmpty {
                Text("지금 \(route.connectStopName)에 오는 버스 정보가 없어요. 열차 도착 20~30분 전부터 나타나요.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(0..<min(8, items.count), id: \.self) { index in
                    let item = items[index]
                    let busTime = now.addingTimeInterval(Double(item.remaining))
                    HStack {
                        Text(item.arrival.routeNo)
                            .font(.title3.bold().monospacedDigit())
                        Text(TimeText.clock(busTime))
                            .font(.body.monospacedDigit())
                            .foregroundColor(.secondary)
                        Spacer()
                        if let ready {
                            if busTime >= ready {
                                Text("탑승 가능 · 대기 \(Int(busTime.timeIntervalSince(ready)) / 60)분")
                                    .font(.caption.bold())
                                    .foregroundColor(.green)
                            } else {
                                Text("열차 도착 전")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            Text(item.remaining < 60 ? "곧 도착" : "\(item.remaining / 60)분 후")
                                .font(.caption.bold())
                        }
                    }
                }
            }

            if let state, state.candidates.count > 1 {
                Picker("정류장", selection: Binding(
                    get: { state.stop?.id ?? "" },
                    set: { id in
                        guard let stop = state.candidates.first(where: { $0.id == id }) else { return }
                        bus.choose(stop, for: route, kind: .connect, store: store)
                        Task {
                            if let current = store.route(id: route.id) {
                                await bus.refresh(route: current, kind: .connect, key: apiKey, store: store, minInterval: 0)
                            }
                        }
                    }
                )) {
                    ForEach(state.candidates) { stop in
                        Text(stop.label).tag(stop.id)
                    }
                }
            }
        } header: {
            Text("🚌 \(route.connectStopName) → \(route.connectDestination) 연계 · \(state?.stop?.label ?? route.connectStopName)")
        } footer: {
            Text("열차 도착 시각 + 환승 \(route.connectTransferMinutes)분 이후에 오는 버스를 ‘탑승 가능’으로 표시해요. \(route.connectStopName) 정류장은 방향별로 여러 개라서, 명촌 방면 정류장이 맞는지 정류장 번호를 확인하고 아니면 위에서 바꿔 주세요.")
        }
    }

    private func liveBusSection(_ route: Route, now: Date) -> some View {
        let state = bus.state(for: route)
        let upcoming = bus.upcoming(for: route, now: now)

        return Section {
            if apiKey.isEmpty {
                Text("홈 화면 ⚙︎ 설정에서 인증키를 넣으면 실시간 도착정보를 볼 수 있어요.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if let error = state?.error {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            } else if state?.fetchedAt == nil {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("불러오는 중…")
                        .foregroundColor(.secondary)
                }
            } else if upcoming.isEmpty {
                Text("지금 오는 경유버스가 없어요. 차고지에서 아직 출발하지 않은 버스는 도착정보에 나오지 않을 수 있어요.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(0..<min(6, upcoming.count), id: \.self) { index in
                    let item = upcoming[index]
                    HStack {
                        Text(item.arrival.routeNo)
                            .font(.title3.bold().monospacedDigit())
                        if item.arrival.vehicleType.contains("저상") {
                            Text("저상")
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.blue.opacity(0.15), in: Capsule())
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(item.remaining < 60 ? "곧 도착" : "\(item.remaining / 60)분 후")
                                .font(.body.bold().monospacedDigit())
                                .foregroundColor(.green)
                            if item.arrival.stopsAway > 0 {
                                Text("\(item.arrival.stopsAway)정거장 전")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }

            if let state, state.candidates.count > 1 {
                Picker("정류장", selection: Binding(
                    get: { state.stop?.id ?? "" },
                    set: { id in
                        guard let stop = state.candidates.first(where: { $0.id == id }) else { return }
                        bus.choose(stop, for: route, store: store)
                        Task {
                            if let current = store.route(id: route.id) {
                                await bus.refresh(route: current, key: apiKey, store: store, minInterval: 0)
                            }
                        }
                    }
                )) {
                    ForEach(state.candidates) { stop in
                        Text(stop.label).tag(stop.id)
                    }
                }
            }
        } header: {
            Text("🚌 실시간 도착 · \(state?.stop?.label ?? route.busOrigin)")
        } footer: {
            if let fetched = state?.fetchedAt, state?.error == nil {
                Text("\(fetched.formatted(date: .omitted, time: .standard)) 기준 · 30초마다 갱신")
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
