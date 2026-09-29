import Foundation

/// Where a Claude Code session runs: the terminal CLI or Xcode's coding assistant.
enum Harness: String, Equatable, Sendable {
    case claude, xcode

    var title: String {
        switch self {
        case .claude: "Claude"
        case .xcode: "Xcode"
        }
    }
}

struct LiveSession: Identifiable, Equatable, Sendable {
    var id: String
    var harness: Harness
    /// Claude session id when we found one. Totals dedupe on this.
    var usageKey: String
    var model: String
    var project: String
    var elapsed: String
    var costUSD: Double?
    var tokens: Int?
    /// Share of the context window the latest turn used, 0–100.
    var context: Double?
    /// Last line written to the transcript.
    var lastActivity: Date?
    var cwd: String?

    /// Claude Code writes while it works, so a fresh transcript means a turn is running.
    func isWorking(now: Date = Date()) -> Bool {
        guard let lastActivity else { return false }
        return now.timeIntervalSince(lastActivity) < 30
    }
}

struct ProcessSnapshot: Equatable, Sendable {
    var pid: Int
    var elapsed: String
    var command: String
    var cwd: String?
    var openJSONL: [String]
    var envModel: String?
}

struct CostEvent: Equatable, Sendable {
    var sessionID: String
    var model: String
    var usd: Double
    var timestamp: String
}

struct ModelRollup: Identifiable, Equatable, Sendable {
    var id: String { model }
    var model: String
    var sessions: Int
    var costUSD: Double
    var tokens: Int

    /// Local usage of the models that are actually open. Used when the account
    /// API has no per-model window.
    static func make(_ sessions: [LiveSession]) -> [ModelRollup] {
        var order: [String] = []
        var seenKeys: [String: Set<String>] = [:]
        var counts: [String: Int] = [:]
        var usd: [String: Double] = [:]
        var tokens: [String: Int] = [:]
        for session in sessions {
            if !order.contains(session.model) { order.append(session.model) }
            counts[session.model, default: 0] += 1
            var keys = seenKeys[session.model, default: []]
            guard keys.insert(session.usageKey).inserted else { continue }
            seenKeys[session.model] = keys
            if let cost = session.costUSD { usd[session.model, default: 0] += cost }
            if let count = session.tokens { tokens[session.model, default: 0] += count }
        }
        return order.map {
            ModelRollup(model: $0, sessions: counts[$0] ?? 0, costUSD: usd[$0] ?? 0, tokens: tokens[$0] ?? 0)
        }
    }
}

struct OpenTotals: Equatable, Sendable {
    var sessions: Int
    var claudeUSD: Double

    /// Xcode and the terminal can run the same session: its cost counts once.
    static func make(_ sessions: [LiveSession]) -> OpenTotals {
        var seen = Set<String>()
        var usd = 0.0
        for session in sessions {
            guard let cost = session.costUSD, seen.insert(session.usageKey).inserted else { continue }
            usd += cost
        }
        return OpenTotals(sessions: sessions.count, claudeUSD: usd)
    }
}

enum SessionLogic {
    private static let uuidPattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#

    static func sessions(processes: [ProcessSnapshot], costs: [CostEvent]) -> [LiveSession] {
        processes.compactMap { process in
            guard let harness = classify(process.command) else { return nil }
            let sessionID = sessionID(command: process.command, openJSONL: process.openJSONL)
            let fallback = configuredModel(command: process.command, envModel: process.envModel)
            let usage = modelAndCost(sessionID: sessionID, costs: costs, envModel: fallback)
            return LiveSession(
                id: "\(process.pid)",
                harness: harness,
                usageKey: sessionID ?? "pid:\(process.pid)",
                model: usage.model,
                project: projectName(process.cwd),
                elapsed: process.elapsed,
                costUSD: usage.cost,
                tokens: nil,
                cwd: process.cwd
            )
        }
    }

    static func classify(_ command: String) -> Harness? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.split(whereSeparator: \.isWhitespace).first else { return nil }
        let base = URL(fileURLWithPath: String(first)).lastPathComponent
        guard base == "claude" || base.hasPrefix("claude-") else { return nil }
        if trimmed.contains("Xcode/CodingAssistant") || trimmed.contains("XcodeVersions") {
            return .xcode
        }
        return .claude
    }

    static func sessionID(command: String, openJSONL: [String]) -> String? {
        if let resumed = firstUUID(afterResumeFlagIn: command) { return resumed }
        let candidates = openJSONL
            .filter { $0.contains("/.claude/projects/") && $0.hasSuffix(".jsonl") && !$0.contains("/subagents/") }
            .sorted()
        for path in candidates {
            if let id = firstUUID(in: URL(fileURLWithPath: path).lastPathComponent) { return id }
        }
        return nil
    }

    /// The model Xcode/Claude put in the process settings wins over a generic
    /// `ANTHROPIC_MODEL=best` sitting in the environment.
    static func configuredModel(command: String, envModel: String?) -> String? {
        if let inline = firstCapture(in: command, pattern: #"ANTHROPIC_MODEL"\s*:\s*"([^"]+)""#),
           !inline.isEmpty {
            return inline
        }
        if let envModel, !envModel.isEmpty { return envModel }
        return nil
    }

    static func projectName(_ cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty, cwd != "/" else { return "—" }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    static func modelAndCost(
        sessionID: String?,
        costs: [CostEvent],
        envModel: String?
    ) -> (model: String, cost: Double?) {
        guard let sessionID else {
            return (envModel?.isEmpty == false ? envModel! : "Claude", nil)
        }
        let rows = costs.filter { $0.sessionID == sessionID }
        guard !rows.isEmpty else {
            return (envModel?.isEmpty == false ? envModel! : "Claude", nil)
        }
        // Each row is the session's running total, so the latest one is the cost.
        let latest = rows.max { $0.timestamp < $1.timestamp }
        let model = latest.flatMap { $0.model == "unknown" ? nil : $0.model } ?? envModel ?? "Claude"
        return (model, latest?.usd)
    }

    /// Claude Code does not keep its transcript open between writes, so a
    /// process without `--resume` often shows no file. Each such process takes
    /// the newest transcript in its project folder that no other process claimed.
    static func guessTranscripts(
        _ processes: [ProcessSnapshot],
        recent: (String) -> [String]
    ) -> [ProcessSnapshot] {
        var claimed = Set<String>()
        for process in processes {
            if let id = sessionID(command: process.command, openJSONL: process.openJSONL) { claimed.insert(id) }
        }
        return processes.map { process in
            guard sessionID(command: process.command, openJSONL: process.openJSONL) == nil,
                  let cwd = process.cwd
            else { return process }
            for path in recent(cwd) {
                guard let id = firstUUID(in: URL(fileURLWithPath: path).lastPathComponent),
                      claimed.insert(id).inserted else { continue }
                var copy = process
                copy.openJSONL = [path]
                return copy
            }
            return process
        }
    }

    /// Transcript files for the open sessions, so the scan reads them even
    /// when they have been quiet since the stats cutoff.
    static func transcriptPaths(
        processes: [ProcessSnapshot],
        locate: (String) -> String? = { TranscriptScan.path(sessionID: $0) }
    ) -> [String] {
        processes.compactMap { process in
            guard classify(process.command) != nil else { return nil }
            if let open = process.openJSONL.first(where: { !TranscriptScan.isSubagent($0) }) { return open }
            return sessionID(command: process.command, openJSONL: process.openJSONL).flatMap(locate)
        }
    }

    /// Adds what the transcript knows: live model, context use, tokens, last write.
    static func attach(_ sessions: [LiveSession], transcripts: [String: TranscriptState]) -> [LiveSession] {
        var byID: [String: TranscriptState] = [:]
        for (path, state) in transcripts where !TranscriptScan.isSubagent(path) {
            guard let id = state.sessionID ?? firstUUID(in: URL(fileURLWithPath: path).lastPathComponent) else { continue }
            byID[id] = state
        }
        return sessions.map { session in
            guard let state = byID[session.usageKey] else { return session }
            var copy = session
            if let model = state.model { copy.model = model }
            if let used = state.context {
                copy.context = min(100, Double(used) / Double(ModelMatch.contextWindow(used: used)) * 100)
            }
            let total = state.total.tokens
            if total > 0 { copy.tokens = total }
            copy.lastActivity = [state.lastLine, state.modified].compactMap { $0 }.max()
            return copy
        }
    }

    static func parseCosts(_ text: String) -> [CostEvent] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sessionID = object["session_id"] as? String,
                  let model = object["model"] as? String,
                  let timestamp = object["timestamp"] as? String,
                  let usd = doubleValue(object["estimated_cost_usd"])
            else { return nil }
            return CostEvent(sessionID: sessionID, model: model, usd: usd, timestamp: timestamp)
        }
    }

    static func parseProcessLine(_ line: String) -> (pid: Int, elapsed: String, command: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let pattern = #"^(\d+)\s+(\S+)\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let pidRange = Range(match.range(at: 1), in: trimmed),
              let elapsedRange = Range(match.range(at: 2), in: trimmed),
              let commandRange = Range(match.range(at: 3), in: trimmed),
              let pid = Int(trimmed[pidRange])
        else { return nil }
        return (pid, String(trimmed[elapsedRange]), String(trimmed[commandRange]))
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    private static func firstUUID(afterResumeFlagIn command: String) -> String? {
        guard let flag = command.range(of: "--resume") else { return nil }
        return firstUUID(in: String(command[flag.upperBound...]))
    }

    private static func firstUUID(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: uuidPattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text)
        else { return nil }
        return String(text[range])
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let number as Double: return number
        case let number as Int: return Double(number)
        case let number as NSNumber: return number.doubleValue
        default: return nil
        }
    }
}
