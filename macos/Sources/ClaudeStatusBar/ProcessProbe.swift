import Foundation

enum Shell {
    static func run(_ launchPath: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        // A pipe deadlocks once `ps` fills it: the Xcode Claude command line is
        // larger than the pipe buffer, and we would be waiting for `ps` to exit
        // before reading. A file has no buffer ceiling.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("claude-status-bar-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { return "" }
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
            return ""
        }
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? handle.close()
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: url)
        return text
    }
}

enum ProcessProbe {
    static func snapshot() -> [ProcessSnapshot] {
        let text = Shell.run("/bin/ps", ["-ax", "-o", "pid=,etime=,command="])
        let found: [ProcessSnapshot] = text.split(separator: "\n").compactMap { raw in
            let line = String(raw)
            guard let parsed = SessionLogic.parseProcessLine(line),
                  SessionLogic.classify(parsed.command) != nil
            else { return nil }
            let cwd = workingDirectory(pid: parsed.pid)
            let hasResume = SessionLogic.sessionID(command: parsed.command, openJSONL: []) != nil
            let jsonl = hasResume ? [] : openTranscripts(pid: parsed.pid)
            let envModel = anthropicModel(pid: parsed.pid)
            return ProcessSnapshot(
                pid: parsed.pid,
                elapsed: parsed.elapsed,
                command: parsed.command,
                cwd: cwd,
                openJSONL: jsonl,
                envModel: envModel
            )
        }
        return SessionLogic.guessTranscripts(found) { TranscriptScan.recent(cwd: $0) }
    }

    private static func workingDirectory(pid: Int) -> String? {
        let text = Shell.run("/usr/sbin/lsof", ["-n", "-P", "-a", "-p", String(pid), "-d", "cwd", "-F", "n"])
        for line in text.split(separator: "\n") where line.hasPrefix("n") {
            return String(line.dropFirst())
        }
        return nil
    }

    private static func openTranscripts(pid: Int) -> [String] {
        let text = Shell.run("/usr/sbin/lsof", ["-n", "-P", "-p", String(pid), "-F", "n"])
        return text.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("n") else { return nil }
            let path = String(line.dropFirst())
            guard path.contains("/.claude/projects/"), path.hasSuffix(".jsonl") else { return nil }
            return path
        }
    }

    /// Reads one env var off the process. The rest of the environment is discarded.
    private static func anthropicModel(pid: Int) -> String? {
        let text = Shell.run("/bin/ps", ["eww", "-p", String(pid), "-o", "command="])
        guard let regex = try? NSRegularExpression(pattern: #"ANTHROPIC_MODEL=(\S+)"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        let value = String(text[range])
        return value.isEmpty ? nil : value
    }
}

enum CostLog {
    static func load(url: URL) -> [CostEvent] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return SessionLogic.parseCosts(text)
    }

    /// Spend since `since`. Rows are running totals per session, so each
    /// session adds its latest total minus the last total it had before `since`.
    static func spentUSD(_ costs: [CostEvent], since: Date) -> Double {
        var total = 0.0
        for rows in Dictionary(grouping: costs, by: \.sessionID).values {
            let dated = rows.compactMap { row in HistoryLog.parseDate(row.timestamp).map { ($0, row.usd) } }
                .sorted { $0.0 < $1.0 }
            guard let latest = dated.last, latest.0 >= since else { continue }
            let before = dated.last { $0.0 < since }?.1 ?? 0
            total += max(0, latest.1 - before)
        }
        return total
    }

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/metrics/costs.jsonl")
    }
}
