import Foundation

enum ModelFamily: Equatable, Sendable {
    case opus, sonnet, haiku

    init?(localModelID: String) {
        let folded = localModelID.lowercased()
        if folded.contains("opus") || folded == "opusplan" {
            self = .opus
        } else if folded.contains("sonnet") {
            self = .sonnet
        } else if folded.contains("haiku") {
            self = .haiku
        } else {
            return nil
        }
    }

    func matches(displayName: String) -> Bool {
        displayName.lowercased().contains(label)
    }

    private var label: String {
        switch self {
        case .opus: "opus"
        case .sonnet: "sonnet"
        case .haiku: "haiku"
        }
    }
}

enum ModelMatch {
    /// Live families move to the top. Order inside each group stays put.
    static func pinLive(_ rows: [PerModelUsage], liveModelIDs: [String]) -> [PerModelUsage] {
        let families = liveModelIDs.compactMap(ModelFamily.init(localModelID:))
        let marked: [PerModelUsage] = rows.map { row in
            var copy = row
            copy.live = families.contains { $0.matches(displayName: row.displayName) }
            return copy
        }
        return marked.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.live != rhs.element.live { return lhs.element.live }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// The transcript does not say whether the 1M window is on, but a prompt
    /// past 200k can only fit in it.
    static func contextWindow(used: Int) -> Int {
        used > 200_000 ? 1_000_000 : 200_000
    }

    /// "claude-opus-5-5" → "Opus 5.5", "claude-haiku-4-5-20251001" → "Haiku 4.5".
    /// Anything that is not a Claude id stays as it is.
    static func displayName(_ id: String) -> String {
        let parts = id.split(separator: "-").map(String.init)
        guard parts.count >= 2, parts[0] == "claude" else { return id }
        let versions = parts.dropFirst(2).filter { $0.count <= 2 && Int($0) != nil }
        return ([parts[1].capitalized] + [versions.joined(separator: ".")])
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Highest weekly percent among rows that match a live session.
    static func hottestLivePercent(_ rows: [PerModelUsage]) -> Double? {
        rows.filter(\.live).map(\.percent).max()
    }
}

enum Threshold {
    /// Same bands as the terminal statusline: green under 70, amber under 90, red at 90+.
    static func level(_ percent: Double) -> Level {
        if percent < 70 { return .green }
        if percent < 90 { return .amber }
        return .red
    }

    /// The statusline's context pill: green under 55, amber under 75, red at 75+.
    static func contextLevel(_ percent: Double) -> Level {
        if percent < 55 { return .green }
        if percent < 75 { return .amber }
        return .red
    }

    enum Level: Sendable { case green, amber, red }
}

enum Money {
    static let fallbackBRL = 5.40

    static func rate(contents: String?) -> Double {
        guard let contents else { return fallbackBRL }
        let value = Double(contents.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let value, value > 0, value < 100 else { return fallbackBRL }
        return value
    }

    /// Costs come in USD. In Brazil they show in reais at the cached rate;
    /// anywhere else they stay in dollars. Separators follow the locale.
    static func cost(usd: Double, rate: Double, locale: Locale = .current) -> String {
        if locale.region == .brazil {
            return (usd * rate).formatted(.currency(code: "BRL").locale(locale))
        }
        return self.usd(usd, locale: locale)
    }

    static func usd(_ amount: Double, locale: Locale = .current) -> String {
        amount.formatted(.currency(code: "USD").locale(locale))
    }

    /// "7,0 bi", "7.0B", "7,0 Md": the locale's own abbreviations.
    static func tokens(_ count: Int, locale: Locale = .current) -> String {
        let digits = count >= 1_000_000 ? 1...1 : 0...1
        return count.formatted(.number.notation(.compactName).precision(.fractionLength(digits)).locale(locale))
    }
}
