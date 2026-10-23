import SwiftUI

/// ‘버스’ 탭: 명촌차고지 → 태화강역 (퇴근), 태화강역 → 명촌공영차고지 (출근 환승) 실시간 도착
struct BusBoardView: View {
    @EnvironmentObject private var store: RouteStore
    @EnvironmentObject private var bus: BusStore
    @EnvironmentObject private var weather: WeatherStore
    @Environment(\.openURL) private var openURL
    @AppStorage(RailAPI.keyStorage) private var apiKey = ""
    @AppStorage(DayOverride.storageKey) private var dayOverrideRaw = ""

    /// 역까지 가는 버스가 있는 노선 (퇴근 동해선: 명촌차고지 → 태화강역)
    private var originRoute: Route? { store.routes.first { $0.hasBus(.origin) } }
    /// 내린 뒤 갈아탈 버스가 있는 노선 (출근 동해선: 태화강역 → 명촌공영차고지)
    private var connectRoute: Route? { store.routes.first { $0.hasBus(.connect) } }

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 5)) { context in
                List {
                    if apiKey.isEmpty {
                        Section {
                            Text("시간표 탭 오른쪽 위 ⚙︎ 설정에서 공공데이터포털 인증키를 넣으면 실시간 버스를 볼 수 있어요.")
                                .font(.callout)
                                .foregroundColor(.secondary)
                        }
                    }
                    if let route = originRoute {
                        originSection(route, now: context.date)
                        trainSection(route, now: context.date)
                    }
                    if let route = connectRoute {
                        connectSection(route, now: context.date)
                    }
                    if originRoute == nil && connectRoute == nil {
                        Section {
                            Text("버스가 등록된 노선이 없어요. 노선 편집에서 ‘역까지 가는 버스’나 ‘내린 뒤 갈아탈 버스’를 넣어 주세요.")
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("버스")
            .refreshable { await refresh(force: true) }
            .task {
                // 이 탭이 보이는 동안 30초마다 갱신
                while !Task.isCancelled {
                    await refresh(force: false)
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                }
            }
        }
    }

    private func refresh(force: Bool) async {
        for route in [originRoute, connectRoute].compactMap({ $0 }) {
            for kind in [BusKind.origin, .connect] where route.hasBus(kind) {
                await bus.refresh(route: route, kind: kind, key: apiKey, store: store, minInterval: force ? 0 : 25)
            }
        }
    }

    // MARK: - 명촌차고지 → 태화강역

    private func originSection(_ route: Route, now: Date) -> some View {
        let state = bus.state(for: route, kind: .origin)
        let items = bus.upcoming(for: route, kind: .origin, now: now)
        return Section {
            arrivals(items: items, state: state, now: now)
            stopPicker(route, kind: .origin, state: state)
            if route.hasCoordinate {
                Button {
                    Task {
                        if let url = await NaverMap.transitRouteURL(for: route) { openURL(url) }
                    }
                } label: {
                    Label("네이버지도에서 대중교통 길찾기", systemImage: "map")
                }
            }
        } header: {
            Text("🚌 \(route.busOrigin) → \(NaverMap.stationName(route.stop))")
        } footer: {
            footer(state: state, extra: "등록한 경유 버스 \(route.busRoutes.count)개 노선만 보여요.")
        }
    }

    /// 버스를 고를 때 같이 보는 다음 동해선 열차
    private func trainSection(_ route: Route, now: Date) -> some View {
        let day = DayOverride.effective(raw: dayOverrideRaw, on: now)
        let trains = route.upcoming(from: now, day: day, limit: 4)
        let forecast: WeatherSnapshot? = {
            guard let lat = route.latitude, let lng = route.longitude else { return nil }
            return weather.snapshot(latitude: lat, longitude: lng, at: now)
        }()
        return Section {
            if trains.isEmpty {
                Text("오늘 남은 열차가 없어요.")
                    .foregroundColor(.secondary)
            }
            ForEach(trains, id: \.minutes) { train in
                HStack {
                    Text(train.text)
                        .font(.headline.monospacedDigit())
                    if let label = route.trainLabel(for: train.minutes, day: train.day) {
                        Text(label)
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    Spacer()
                    if route.walkMinutes > 0 && !train.isTomorrow {
                        Text(train.leaveIn > 0 ? "\(TimeText.clock(train.minutes - route.walkMinutes))까지 출발" : "서둘러야 함")
                            .font(.caption)
                            .foregroundColor(train.leaveIn > 0 ? .secondary : .red)
                    }
                }
            }
            if let forecast {
                let bike = forecast.bikeStatus
                Text("\(bike.icon) \(bike.text) · \(forecast.summary)")
                    .font(.caption)
            }
        } header: {
            Text("🚆 \(route.name) \(route.stop) 출발")
        }
    }

    // MARK: - 태화강역 → 명촌공영차고지

    private func connectSection(_ route: Route, now: Date) -> some View {
        let state = bus.state(for: route, kind: .connect)
        let items = bus.upcoming(for: route, kind: .connect, now: now)
        return Section {
            arrivals(items: items, state: state, now: now)
            stopPicker(route, kind: .connect, state: state)
        } header: {
            Text("🚌 \(route.connectStopName) → \(route.connectDestination)")
        } footer: {
            footer(state: state, extra: "출근 때 태화강역에서 갈아타는 버스예요.")
        }
    }

    // MARK: - 공통

    @ViewBuilder
    private func arrivals(items: [(arrival: BusArrival, remaining: Int)], state: BusStore.State?, now: Date) -> some View {
        if let error = state?.error {
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
            Text("지금 오는 버스 정보가 없어요. 차고지에서 아직 출발하지 않은 버스는 안 나올 수 있어요.")
                .font(.caption)
                .foregroundColor(.secondary)
        } else {
            ForEach(0..<min(10, items.count), id: \.self) { index in
                let item = items[index]
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
                        HStack(spacing: 4) {
                            Text(TimeText.clock(now.addingTimeInterval(Double(item.remaining))))
                            if item.arrival.stopsAway > 0 {
                                Text("· \(item.arrival.stopsAway)정거장 전")
                            }
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func stopPicker(_ route: Route, kind: BusKind, state: BusStore.State?) -> some View {
        if let state, state.candidates.count > 1 {
            Picker("정류장", selection: Binding(
                get: { state.stop?.id ?? "" },
                set: { id in
                    guard let stop = state.candidates.first(where: { $0.id == id }) else { return }
                    bus.choose(stop, for: route, kind: kind, store: store)
                    Task {
                        if let current = store.route(id: route.id) {
                            await bus.refresh(route: current, kind: kind, key: apiKey, store: store, minInterval: 0)
                        }
                    }
                }
            )) {
                ForEach(state.candidates) { stop in
                    Text(stop.label).tag(stop.id)
                }
            }
        }
    }

    @ViewBuilder
    private func footer(state: BusStore.State?, extra: String) -> some View {
        if let fetched = state?.fetchedAt, state?.error == nil {
            Text("\(fetched.formatted(date: .omitted, time: .standard)) 기준 · 30초마다 갱신 · 당겨서 새로고침\n\(extra)")
        } else {
            Text(extra)
        }
    }
}
