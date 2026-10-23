import SwiftUI

@main
struct CommuteTimerApp: App {
    @StateObject private var store = RouteStore()
    @StateObject private var weather = WeatherStore()
    @StateObject private var bus = BusStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(weather)
                .environmentObject(bus)
        }
    }
}

/// 아래 탭: 시간표 | 버스
struct RootView: View {
    enum Tab { case timetable, bus }

    @State private var tab: Tab = .timetable
    /// 시간표 탭에서 열어 둘 노선 화면 (위젯·잠금화면을 눌렀을 때)
    @State private var path: [UUID] = []

    var body: some View {
        TabView(selection: $tab) {
            ContentView(path: $path)
                .tabItem { Label("시간표", systemImage: "tram.fill") }
                .tag(Tab.timetable)
            BusBoardView()
                .tabItem { Label("버스", systemImage: "bus.fill") }
                .tag(Tab.bus)
        }
        // 위젯·잠금화면을 누르면 commutetimer://route/<노선 ID> 로 들어온다 → 그 노선 화면 열기
        .onOpenURL { url in
            if url.host == "route", let id = url.pathComponents.dropFirst().first.flatMap(UUID.init(uuidString:)) {
                tab = .timetable
                path = [id]
            } else if url.host == "bus" {
                tab = .bus
            }
        }
    }
}
