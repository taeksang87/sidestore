import Foundation

struct WeatherSnapshot {
    let temperature: Double
    let rainProbability: Int
    let precipitation: Double
    let weatherCode: Int
    let windSpeed: Double

    var emoji: String {
        switch weatherCode {
        case 0: return "☀️"
        case 1, 2: return "🌤️"
        case 3: return "☁️"
        case 45, 48: return "🌫️"
        case 51, 53, 55, 56, 57, 61, 63, 66, 80, 81: return "🌧️"
        case 65, 67, 82: return "⛈️"
        case 71, 73, 75, 77, 85, 86: return "🌨️"
        case 95, 96, 99: return "⛈️"
        default: return "🌤️"
        }
    }

    var summary: String {
        "\(emoji) \(Int(temperature.rounded()))° · 비\(rainProbability)%"
    }

    /// 출발 시각 날씨로 자전거 이동이 괜찮은지 판단
    var bikeStatus: (icon: String, text: String) {
        if rainProbability >= 70 || precipitation >= 1 { return ("☔️", "자전거 비추천") }
        if rainProbability >= 40 || precipitation > 0 { return ("⚠️", "우산·우비 확인") }
        if windSpeed >= 35 { return ("💨", "강풍 주의") }
        if temperature >= 32 { return ("🥵", "더위 주의") }
        if temperature <= 2 { return ("🥶", "노면·추위 주의") }
        return ("🚲", "자전거 가능")
    }
}

/// Open-Meteo 시간별 예보 (API 키 불필요)
@MainActor
final class WeatherStore: ObservableObject {
    private struct Forecast {
        let times: [Date]
        let snapshots: [WeatherSnapshot]
        let fetchedAt: Date
    }

    private struct Response: Decodable {
        struct Hourly: Decodable {
            let time: [String]
            let temperature_2m: [Double?]
            let precipitation_probability: [Int?]
            let precipitation: [Double?]
            let rain: [Double?]
            let weather_code: [Int?]
            let wind_speed_10m: [Double?]
        }
        let hourly: Hourly
    }

    @Published private var forecasts: [String: Forecast] = [:]
    private var loading: Set<String> = []

    private static func key(_ lat: Double, _ lng: Double) -> String {
        String(format: "%.3f,%.3f", lat, lng)
    }

    func snapshot(latitude: Double, longitude: Double, at date: Date) -> WeatherSnapshot? {
        guard let forecast = forecasts[Self.key(latitude, longitude)], !forecast.times.isEmpty else { return nil }
        var best = 0
        var bestDiff = Double.infinity
        for (i, t) in forecast.times.enumerated() {
            let diff = abs(t.timeIntervalSince(date))
            if diff < bestDiff {
                bestDiff = diff
                best = i
            }
        }
        return forecast.snapshots[best]
    }

    /// 마지막으로 받은 지 10분이 지났으면 새로 받아온다.
    func refreshIfNeeded(latitude: Double, longitude: Double) async {
        let key = Self.key(latitude, longitude)
        if let existing = forecasts[key], Date().timeIntervalSince(existing.fetchedAt) < 600 { return }
        if loading.contains(key) { return }
        loading.insert(key)
        defer { loading.remove(key) }

        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "hourly", value: "temperature_2m,precipitation_probability,precipitation,rain,weather_code,wind_speed_10m"),
            URLQueryItem(name: "timezone", value: "Asia/Seoul"),
            URLQueryItem(name: "forecast_days", value: "2")
        ]
        guard let url = components.url else { return }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            let (data, _) = try await URLSession.shared.data(for: request)
            let hourly = try JSONDecoder().decode(Response.self, from: data).hourly

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"

            var times: [Date] = []
            var snapshots: [WeatherSnapshot] = []
            for (i, text) in hourly.time.enumerated() {
                guard let date = formatter.date(from: text), i < hourly.temperature_2m.count else { continue }
                let precipitation = max(value(hourly.precipitation, i) ?? 0, value(hourly.rain, i) ?? 0)
                times.append(date)
                snapshots.append(WeatherSnapshot(
                    temperature: value(hourly.temperature_2m, i) ?? 0,
                    rainProbability: value(hourly.precipitation_probability, i) ?? 0,
                    precipitation: precipitation,
                    weatherCode: value(hourly.weather_code, i) ?? -1,
                    windSpeed: value(hourly.wind_speed_10m, i) ?? 0
                ))
            }
            forecasts[key] = Forecast(times: times, snapshots: snapshots, fetchedAt: Date())
        } catch {
            print("날씨 불러오기 실패: \(error)")
        }
    }

    private func value<T>(_ array: [T?], _ index: Int) -> T? {
        index < array.count ? array[index] : nil
    }
}
