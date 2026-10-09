import Foundation

/// 대한민국 공휴일. 앱에 넣어 둔 목록 + 특일정보 API(한국천문연구원)로 받은 목록을 합쳐서 쓴다.
enum KoreanHolidays {
    /// 2026~2027 공휴일·대체공휴일 (yyyyMMdd)
    static let builtIn: Set<String> = [
        // 2026
        "20260101", "20260216", "20260217", "20260218", "20260301", "20260302",
        "20260505", "20260524", "20260525", "20260603", "20260606", "20260815", "20260817",
        "20260924", "20260925", "20260926", "20261003", "20261005", "20261009", "20261225",
        // 2027
        "20270101", "20270206", "20270207", "20270208", "20270209", "20270301",
        "20270505", "20270513", "20270606", "20270815", "20270816",
        "20270914", "20270915", "20270916", "20271003", "20271004", "20271009", "20271011",
        "20271225", "20271227"
    ]

    private static let cacheKey = "koreanHolidays"
    private static let syncedKey = "koreanHolidaysSyncedAt"

    private static var downloaded: Set<String> = Set(SharedData.defaults.stringArray(forKey: cacheKey) ?? [])

    static func key(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func isHoliday(_ date: Date) -> Bool {
        let k = key(date)
        return builtIn.contains(k) || downloaded.contains(k)
    }

    /// API로 받은 공휴일 저장 (해당 연도 것은 새 목록으로 교체)
    static func store(_ dates: [String], years: [Int]) {
        let prefixes = years.map { String($0) }
        var merged = downloaded.filter { date in !prefixes.contains { date.hasPrefix($0) } }
        merged.formUnion(dates)
        downloaded = merged
        SharedData.defaults.set(Array(merged).sorted(), forKey: cacheKey)
        SharedData.defaults.set(Date(), forKey: syncedKey)
    }

    static var needsSync: Bool {
        guard let synced = SharedData.defaults.object(forKey: syncedKey) as? Date else { return true }
        return Date().timeIntervalSince(synced) > 20 * 86400
    }
}
