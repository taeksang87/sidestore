import CoreLocation
import Foundation

enum NaverMap {
    /// 버스 출발지 → 타는 역 대중교통 길찾기 (네이버지도 앱 URL 스킴)
    static func transitRouteURL(for route: Route) async -> URL? {
        guard let lat = route.latitude, let lng = route.longitude else { return nil }
        var items: [String] = []

        if !route.busOriginAddress.isEmpty,
           let placemarks = try? await CLGeocoder().geocodeAddressString(route.busOriginAddress),
           let location = placemarks.first?.location {
            items += [
                "slat=\(location.coordinate.latitude)",
                "slng=\(location.coordinate.longitude)",
                "sname=\(encode(route.busOrigin.isEmpty ? route.busOriginAddress : route.busOrigin))"
            ]
        }
        // 출발지를 못 찾으면 네이버지도가 현재 위치에서 출발하도록 비워 둔다.

        items += [
            "dlat=\(lat)",
            "dlng=\(lng)",
            "dname=\(encode(stationName(route.stop)))",
            "appname=\(Bundle.main.bundleIdentifier ?? "app.commutetimer")"
        ]
        return URL(string: "nmap://route/public?" + items.joined(separator: "&"))
    }

    static func stationName(_ stop: String) -> String {
        stop.hasSuffix("역") || stop.isEmpty ? stop : stop + "역"
    }

    private static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? text
    }
}
