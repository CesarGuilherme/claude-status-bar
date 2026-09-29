import Foundation

/// `~/.claude/stats-cache.json`, the file Claude Code's `/stats` reads. It is an
/// internal format, so every field is optional and a missing one only drops
/// that piece. It is computed up to `lastComputedDate`; later days come from
/// the transcripts.
struct StatsCache: Equatable, Sendable {
    var lastComputed: Date?
    var days: [Date: HistoryDay]
    var models: [String: TokenSplit]
    var longest: SessionMark?

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/stats-cache.json")
    }

    static func load(url: URL = defaultURL, calendar: Calendar = .current) -> StatsCache? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data, calendar: calendar)
    }

    static func parse(_ data: Data, calendar: Calendar = .current) -> StatsCache? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var days: [Date: HistoryDay] = [:]
        for item in root["dailyActivity"] as? [[String: Any]] ?? [] {
            guard let day = day(item["date"], calendar: calendar) else { continue }
            days[day, default: HistoryDay()].sessions += int(item["sessionCount"])
            days[day, default: HistoryDay()].activity += int(item["messageCount"])
        }
        for item in root["dailyModelTokens"] as? [[String: Any]] ?? [] {
            guard let day = day(item["date"], calendar: calendar),
                  let byModel = item["tokensByModel"] as? [String: Any] else { continue }
            for (model, tokens) in byModel {
                days[day, default: HistoryDay()].models[model, default: TokenSplit()].unsplit += int(tokens)
            }
        }
        var models: [String: TokenSplit] = [:]
        for (model, value) in root["modelUsage"] as? [String: Any] ?? [:] {
            guard let usage = value as? [String: Any] else { continue }
            let split = TokenSplit(
                input: int(usage["inputTokens"]),
                output: int(usage["outputTokens"]),
                cacheRead: int(usage["cacheReadInputTokens"]),
                cacheWrite: int(usage["cacheCreationInputTokens"])
            )
            if split.tokens > 0 { models[model] = split }
        }
        var longest: SessionMark?
        if let session = root["longestSession"] as? [String: Any],
           let start = HistoryLog.parseDate(session["timestamp"] as? String ?? "") {
            longest = SessionMark(start: start, duration: Double(int(session["duration"])) / 1000)
        }
        guard !days.isEmpty || !models.isEmpty else { return nil }
        return StatsCache(
            lastComputed: day(root["lastComputedDate"], calendar: calendar),
            days: days,
            models: models,
            longest: longest
        )
    }

    /// Transcript activity from this instant on is not in the cache yet.
    func cutoff(calendar: Calendar = .current) -> Date {
        guard let lastComputed else { return .distantPast }
        return calendar.date(byAdding: .day, value: 1, to: lastComputed) ?? lastComputed
    }

    private static func day(_ value: Any?, calendar: Calendar) -> Date? {
        guard let text = value as? String else { return nil }
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func int(_ value: Any?) -> Int {
        switch value {
        case let number as Int: number
        case let number as NSNumber: number.intValue
        default: 0
        }
    }
}
