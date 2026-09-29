import Foundation

enum HistoryRange: String, CaseIterable, Identifiable, Sendable {
    case all, month, week
    var id: String { rawValue }
    var title: String {
        switch self {
        case .week: "7 dias"
        case .month: "30 dias"
        case .all: "Tudo"
        }
    }
}

struct HistoryEvent: Equatable, Sendable {
    var timestamp: Date
    var model: String
    var sessionID: String
    var input: Int
    var output: Int
    var cacheRead: Int
    var cacheWrite: Int

    var tokens: Int { input + output + cacheRead + cacheWrite }
    var split: TokenSplit { TokenSplit(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite) }
}

/// Token counts by kind. `unsplit` holds totals that came without the split
/// (the per-day numbers in stats-cache), so they count but are never shown as
/// input or output.
struct TokenSplit: Equatable, Sendable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    var unsplit = 0

    var tokens: Int { input + output + cacheRead + cacheWrite + unsplit }
    var isSplit: Bool { unsplit == 0 }

    static func + (lhs: TokenSplit, rhs: TokenSplit) -> TokenSplit {
        TokenSplit(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
            unsplit: lhs.unsplit + rhs.unsplit
        )
    }

    static func += (lhs: inout TokenSplit, rhs: TokenSplit) { lhs = lhs + rhs }
}

/// One calendar day. `sessions` counts sessions that started that day;
/// `activity` (messages or events) drives the heatmap.
struct HistoryDay: Equatable, Sendable {
    var models: [String: TokenSplit] = [:]
    var sessions = 0
    var activity = 0

    var tokens: Int { models.values.reduce(0) { $0 + $1.tokens } }
    var isActive: Bool { activity > 0 || tokens > 0 }
}

struct SessionMark: Equatable, Sendable {
    var start: Date
    var duration: TimeInterval
}

/// Everything a snapshot needs, by day. `allTime`, when present, is the exact
/// per-model split for the "Tudo" range.
struct HistoryInput: Equatable, Sendable {
    var days: [Date: HistoryDay] = [:]
    var allTime: [String: TokenSplit]?
    var marks: [SessionMark] = []

    init(days: [Date: HistoryDay] = [:], allTime: [String: TokenSplit]? = nil, marks: [SessionMark] = []) {
        self.days = days
        self.allTime = allTime
        self.marks = marks
    }

    init(events: [HistoryEvent], calendar: Calendar = .current) {
        var spans: [String: (first: Date, last: Date)] = [:]
        for event in events {
            let day = calendar.startOfDay(for: event.timestamp)
            days[day, default: HistoryDay()].models[event.model, default: TokenSplit()] += event.split
            days[day, default: HistoryDay()].activity += 1
            let span = spans[event.sessionID] ?? (event.timestamp, event.timestamp)
            spans[event.sessionID] = (min(span.first, event.timestamp), max(span.last, event.timestamp))
        }
        for span in spans.values {
            days[calendar.startOfDay(for: span.first), default: HistoryDay()].sessions += 1
            marks.append(SessionMark(start: span.first, duration: span.last.timeIntervalSince(span.first)))
        }
    }
}

struct HistoryCell: Equatable, Sendable, Identifiable {
    var day: Date
    var heat: Int
    var tokens: Int
    var included: Bool
    var id: Date { day }
}

struct HistoryWeek: Equatable, Sendable, Identifiable {
    var start: Date
    var monthLabel: String?
    var days: [HistoryCell]
    var id: Date { start }
}

struct HistoryPoint: Equatable, Sendable, Identifiable {
    var day: Date
    var model: String
    var tokens: Int
    var id: String { "\(model)|\(day.timeIntervalSinceReferenceDate)" }
}

struct ModelShare: Equatable, Sendable, Identifiable {
    var model: String
    var tokens: Int
    var input: Int
    var output: Int
    var cacheRead: Int
    var cacheWrite: Int
    var percent: Double
    /// False when part of this model's tokens came without the input/output split.
    var splitKnown: Bool = true
    var id: String { model }
}

struct HistorySnapshot: Equatable, Sendable {
    var favoriteModel: String
    var totalTokens: Int
    var sessions: Int
    var activeDays: Int
    var spanDays: Int
    var busiestDay: Date?
    var longestSession: TimeInterval
    var longestStreak: Int
    var currentStreak: Int
    var input: Int
    var output: Int
    var cacheRead: Int
    var cacheWrite: Int
    var splitKnown: Bool = true
    var weeks: [HistoryWeek]
    var series: [HistoryPoint]
    var models: [String]
    var shares: [ModelShare]
    var peak: Int

    static let empty = HistorySnapshot(
        favoriteModel: "—",
        totalTokens: 0,
        sessions: 0,
        activeDays: 0,
        spanDays: 0,
        busiestDay: nil,
        longestSession: 0,
        longestStreak: 0,
        currentStreak: 0,
        input: 0,
        output: 0,
        cacheRead: 0,
        cacheWrite: 0,
        weeks: [],
        series: [],
        models: [],
        shares: [],
        peak: 0
    )
}

enum HistoryLog {
    /// Each costs.jsonl row is the session's running total (ECC cost-tracker),
    /// so the event for a row is its difference from the row before.
    static func claudeEvents(text: String) -> [HistoryEvent] {
        let rows: [HistoryEvent] = text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sessionID = object["session_id"] as? String,
                  let timestamp = parseDate(object["timestamp"] as? String ?? "")
            else { return nil }
            let model = (object["model"] as? String).flatMap { $0.isEmpty || $0 == "unknown" ? nil : $0 } ?? "Claude"
            return HistoryEvent(
                timestamp: timestamp,
                model: model,
                sessionID: sessionID,
                input: intValue(object["input_tokens"]),
                output: intValue(object["output_tokens"]),
                cacheRead: intValue(object["cache_read_tokens"]),
                cacheWrite: intValue(object["cache_write_tokens"])
            )
        }
        var previous: [String: HistoryEvent] = [:]
        return rows.sorted { $0.timestamp < $1.timestamp }.map { row in
            defer { previous[row.sessionID] = row }
            guard let before = previous[row.sessionID] else { return row }
            var delta = row
            delta.input = max(0, row.input - before.input)
            delta.output = max(0, row.output - before.output)
            delta.cacheRead = max(0, row.cacheRead - before.cacheRead)
            delta.cacheWrite = max(0, row.cacheWrite - before.cacheWrite)
            return delta
        }
    }

    /// Claude history the way `/stats` sees it: stats-cache up to its last
    /// computed day, transcripts after that. Without the cache, the cost log.
    static func claudeInput(
        cache: StatsCache?,
        transcripts: [String: TranscriptState],
        costsText: String,
        calendar: Calendar = .current
    ) -> HistoryInput {
        guard let cache else {
            return HistoryInput(events: claudeEvents(text: costsText), calendar: calendar)
        }
        let cutoff = cache.cutoff(calendar: calendar)
        var input = HistoryInput(days: cache.days, allTime: cache.models, marks: cache.longest.map { [$0] } ?? [])
        for (path, state) in transcripts {
            for message in state.messages where message >= cutoff {
                input.days[calendar.startOfDay(for: message), default: HistoryDay()].activity += 1
            }
            for usage in state.usage.values where usage.timestamp >= cutoff {
                let day = calendar.startOfDay(for: usage.timestamp)
                input.days[day, default: HistoryDay()].models[usage.model, default: TokenSplit()] += usage.split
                input.allTime?[usage.model, default: TokenSplit()] += usage.split
            }
            guard !TranscriptScan.isSubagent(path), let start = state.start, let last = state.lastLine else { continue }
            if start >= cutoff {
                input.days[calendar.startOfDay(for: start), default: HistoryDay()].sessions += 1
            }
            if last >= cutoff {
                input.marks.append(SessionMark(start: start, duration: last.timeIntervalSince(start)))
            }
        }
        return input
    }

    static func grokEvents(root: URL, fileManager: FileManager = .default) -> [HistoryEvent] {
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var events: [HistoryEvent] = []
        for case let url as URL in enumerator where url.lastPathComponent == "usage.json" {
            guard let data = try? Data(contentsOf: url) else { continue }
            events.append(contentsOf: parseGrok(data))
        }
        return events
    }

    static func parseGrok(_ data: Data) -> [HistoryEvent] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionID = root["sessionId"] as? String,
              let turns = root["turns"] as? [[String: Any]]
        else { return [] }
        return turns.compactMap { turn in
            guard let timestamp = parseDate(turn["endedAt"] as? String ?? "") else { return nil }
            let model = (turn["primaryModelId"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Grok"
            return HistoryEvent(
                timestamp: timestamp,
                model: model,
                sessionID: sessionID,
                input: intValue(turn["inputTokens"]),
                output: intValue(turn["outputTokens"]),
                cacheRead: intValue(turn["cachedReadTokens"]),
                cacheWrite: intValue(turn["cacheCreationTokens"])
            )
        }
    }

    /// Grok writes six fractional digits. Apple's ISO parser stops at three.
    static func parseDate(_ text: String) -> Date? {
        let normalized = normalizeISO(text)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: normalized) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: normalized)
    }

    static func snapshot(
        events: [HistoryEvent],
        range: HistoryRange,
        now: Date,
        calendar: Calendar = .current
    ) -> HistorySnapshot {
        snapshot(input: HistoryInput(events: events, calendar: calendar), range: range, now: now, calendar: calendar)
    }

    static func snapshot(
        input: HistoryInput,
        range: HistoryRange,
        now: Date,
        calendar: Calendar = .current
    ) -> HistorySnapshot {
        guard let window = windowBounds(days: Array(input.days.keys), range: range, now: now, calendar: calendar) else {
            return .empty
        }
        let included = input.days.filter { $0.key >= window.start && $0.key < window.end }
        guard !included.isEmpty else { return .empty }

        var perModel: [String: TokenSplit] = [:]
        if range == .all, let allTime = input.allTime, !allTime.isEmpty {
            perModel = allTime
        } else {
            for day in included.values {
                for (model, split) in day.models { perModel[model, default: TokenSplit()] += split }
            }
        }
        let totals = perModel.values.reduce(TokenSplit(), +)
        let ranked = perModel.sorted { lhs, rhs in
            if lhs.value.tokens != rhs.value.tokens { return lhs.value.tokens > rhs.value.tokens }
            return lhs.key < rhs.key
        }
        let top = Array(ranked.prefix(4))
        let activeSet = Set(included.filter { $0.value.isActive }.keys)
        let busiest = included.max { lhs, rhs in
            if lhs.value.tokens != rhs.value.tokens { return lhs.value.tokens < rhs.value.tokens }
            return lhs.value.activity < rhs.value.activity
        }
        let longest = input.marks
            .filter { $0.start < window.end && $0.start.addingTimeInterval($0.duration) >= window.start }
            .map(\.duration)
            .max() ?? 0
        let streaks = streaks(active: activeSet, now: now, calendar: calendar)

        let firstDay = window.start
        let lastDay = calendar.date(byAdding: .day, value: -1, to: window.end) ?? window.start
        let gridStart = monday(onOrBefore: firstDay, calendar: calendar)
        let gridEnd = sunday(onOrAfter: lastDay, calendar: calendar)
        var weeks: [HistoryWeek] = []
        var cursor = gridStart
        var labeledMonths: Set<String> = []
        let monthFormatter = DateFormatter()
        monthFormatter.calendar = calendar
        monthFormatter.locale = Locale(identifier: "pt_BR")
        monthFormatter.dateFormat = "MMM"
        while cursor <= gridEnd {
            var days: [HistoryCell] = []
            var label: String?
            for offset in 0..<7 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: cursor) else { continue }
                let record = input.days[day] ?? HistoryDay()
                let inside = day >= firstDay && day <= lastDay
                days.append(HistoryCell(day: day, heat: heat(record), tokens: record.tokens, included: inside))
                let month = monthFormatter.string(from: day)
                if inside, calendar.component(.day, from: day) == 1 || weeks.isEmpty && offset == 0 {
                    if labeledMonths.insert(month).inserted { label = month }
                }
            }
            weeks.append(HistoryWeek(start: cursor, monthLabel: label, days: days))
            guard let next = calendar.date(byAdding: .day, value: 7, to: cursor) else { break }
            cursor = next
        }

        var series: [HistoryPoint] = []
        var dayCursor = firstDay
        while dayCursor <= lastDay {
            let record = input.days[dayCursor]
            for model in top {
                series.append(HistoryPoint(day: dayCursor, model: model.key, tokens: record?.models[model.key]?.tokens ?? 0))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: dayCursor) else { break }
            dayCursor = next
        }

        let shares = top.map { model, split in
            ModelShare(
                model: model,
                tokens: split.tokens,
                input: split.input,
                output: split.output,
                cacheRead: split.cacheRead,
                cacheWrite: split.cacheWrite,
                percent: totals.tokens > 0 ? Double(split.tokens) / Double(totals.tokens) * 100 : 0,
                splitKnown: split.isSplit
            )
        }
        return HistorySnapshot(
            favoriteModel: ranked.first?.key ?? "—",
            totalTokens: totals.tokens,
            sessions: included.values.reduce(0) { $0 + $1.sessions },
            activeDays: activeSet.count,
            spanDays: spanDays(range: range, active: activeSet, calendar: calendar),
            busiestDay: busiest?.key,
            longestSession: longest,
            longestStreak: streaks.longest,
            currentStreak: streaks.current,
            input: totals.input,
            output: totals.output,
            cacheRead: totals.cacheRead,
            cacheWrite: totals.cacheWrite,
            splitKnown: totals.isSplit,
            weeks: weeks,
            series: series,
            models: top.map(\.key),
            shares: shares,
            peak: included.values.map(heat).max() ?? 0
        )
    }

    static func level(tokens: Int, peak: Int) -> Int {
        guard tokens > 0, peak > 0 else { return 0 }
        let ratio = Double(tokens) / Double(peak)
        if ratio < 0.25 { return 1 }
        if ratio < 0.50 { return 2 }
        if ratio < 0.75 { return 3 }
        return 4
    }

    static func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private static func heat(_ day: HistoryDay) -> Int {
        day.activity > 0 ? day.activity : (day.tokens > 0 ? 1 : 0)
    }

    private struct Window {
        var start: Date
        var end: Date
    }

    private static func windowBounds(
        days: [Date],
        range: HistoryRange,
        now: Date,
        calendar: Calendar
    ) -> Window? {
        let today = calendar.startOfDay(for: now)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return nil }
        switch range {
        case .week:
            guard let start = calendar.date(byAdding: .day, value: -6, to: today) else { return nil }
            return Window(start: start, end: tomorrow)
        case .month:
            guard let start = calendar.date(byAdding: .day, value: -29, to: today) else { return nil }
            return Window(start: start, end: tomorrow)
        case .all:
            guard let first = days.min(), let last = days.max() else { return nil }
            let end = calendar.date(byAdding: .day, value: 1, to: last) ?? tomorrow
            return Window(start: first, end: end)
        }
    }

    private static func spanDays(range: HistoryRange, active: Set<Date>, calendar: Calendar) -> Int {
        switch range {
        case .week: return 7
        case .month: return 30
        case .all:
            guard let first = active.min(), let last = active.max() else { return 0 }
            let days = calendar.dateComponents([.day], from: first, to: last).day ?? 0
            return days + 1
        }
    }

    private static func streaks(active: Set<Date>, now: Date, calendar: Calendar) -> (current: Int, longest: Int) {
        let sorted = active.sorted()
        var longest = 0
        var run = 0
        var previous: Date?
        for day in sorted {
            if let previous, let next = calendar.date(byAdding: .day, value: 1, to: previous), next == day {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            previous = day
        }
        var cursor = calendar.startOfDay(for: now)
        if !active.contains(cursor) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor), active.contains(yesterday) else {
                return (0, longest)
            }
            cursor = yesterday
        }
        var current = 0
        while active.contains(cursor) {
            current += 1
            guard let prior = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prior
        }
        return (current, longest)
    }

    private static func monday(onOrBefore day: Date, calendar: Calendar) -> Date {
        let weekday = calendar.component(.weekday, from: day)
        let back = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: -back, to: day) ?? day
    }

    private static func sunday(onOrAfter day: Date, calendar: Calendar) -> Date {
        let weekday = calendar.component(.weekday, from: day)
        let forward = (8 - weekday) % 7
        return calendar.date(byAdding: .day, value: forward, to: day) ?? day
    }

    static func normalizeISO(_ text: String) -> String {
        guard let dot = text.firstIndex(of: ".") else { return text }
        let digitsStart = text.index(after: dot)
        var zone = digitsStart
        while zone < text.endIndex, text[zone].isNumber {
            zone = text.index(after: zone)
        }
        let millis = String(text[digitsStart..<zone].prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
        return String(text[..<digitsStart]) + millis + String(text[zone...])
    }

    private static func intValue(_ value: Any?) -> Int {
        switch value {
        case let number as Int: return number
        case let number as NSNumber: return number.intValue
        default: return 0
        }
    }
}
