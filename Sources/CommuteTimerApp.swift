import SwiftUI

@main
struct CommuteTimerApp: App {
    @StateObject private var store = RouteStore()
    @StateObject private var weather = WeatherStore()
    @StateObject private var bus = BusStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(weather)
                .environmentObject(bus)
        }
    }
}
