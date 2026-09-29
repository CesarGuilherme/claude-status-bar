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

/// Grok's `costUsdTicks` stays out of reais until the divisor is confirmed
/// against a number the TUI already shows.
enum GrokCost {
    static let usdDivisor: Double? = nil

    static func usd(ticks: Int) -> Double? {
        guard let usdDivisor, usdDivisor > 0 else { return nil }
        return Double(ticks) / usdDivisor
    }
}

enum Money {
    static let fallbackBRL = 5.40

    static func rate(contents: String?) -> Double {
        guard let contents else { return fallbackBRL }
        let value = Double(contents.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let value, value > 0, value < 100 else { return fallbackBRL }
        return value
    }

    static func brl(usd: Double, rate: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.numberStyle = .currency
        formatter.currencyCode = "BRL"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: usd * rate)) ?? String(format: "R$ %.2f", usd * rate)
    }

    static func usd(_ amount: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: amount)) ?? String(format: "US$ %.2f", amount)
    }

    static func tokens(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        formatter.minimumFractionDigits = count >= 1_000_000 ? 1 : 0
        if count >= 1_000_000_000 {
            let text = formatter.string(from: NSNumber(value: Double(count) / 1_000_000_000)) ?? "\(count)"
            return "\(text) bi"
        }
        if count >= 1_000_000 {
            let text = formatter.string(from: NSNumber(value: Double(count) / 1_000_000)) ?? "\(count)"
            return "\(text) mi"
        }
        return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }
}
