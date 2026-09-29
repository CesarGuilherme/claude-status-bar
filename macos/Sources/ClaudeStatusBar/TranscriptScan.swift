import Foundation

/// One assistant message's usage, keyed by message id: Claude Code writes the
/// same message on several streamed lines, and summing every line inflates it.
struct MessageUsage: Equatable, Sendable {
    var timestamp: Date
    var model: String
    var split: TokenSplit
}

/// What one transcript has said so far. Transcripts only grow, so each pass
/// parses the bytes after `offset` and keeps the rest.
struct TranscriptState: Equatable, Sendable {
    var offset: UInt64 = 0
    var modified: Date = .distantPast
    var sessionID: String?
    var start: Date?
    var lastLine: Date?
    var model: String?
    /// Prompt size of the latest assistant turn: input + cache read + cache write.
    var context: Int?
    var usage: [String: MessageUsage] = [:]
    var messages: [Date] = []

    var total: TokenSplit {
        usage.values.reduce(TokenSplit()) { $0 + $1.split }
    }

    mutating func consume(_ data: Data) {
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = object["type"] as? String,
                  type == "user" || type == "assistant",
                  let timestamp = HistoryLog.parseDate(object["timestamp"] as? String ?? "")
            else { continue }
            if sessionID == nil { sessionID = object["sessionId"] as? String }
            if start.map({ timestamp < $0 }) ?? true { start = timestamp }
            if lastLine.map({ timestamp > $0 }) ?? true { lastLine = timestamp }
            guard type == "assistant",
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any]
            else {
                messages.append(timestamp)
                continue
            }
            let model = (message["model"] as? String) ?? "Claude"
            guard model != "<synthetic>" else { continue }
            let split = TokenSplit(
                input: Self.int(usage["input_tokens"]),
                output: Self.int(usage["output_tokens"]),
                cacheRead: Self.int(usage["cache_read_input_tokens"]),
                cacheWrite: Self.int(usage["cache_creation_input_tokens"])
            )
            let id = (message["id"] as? String) ?? (object["uuid"] as? String) ?? "\(timestamp.timeIntervalSince1970)"
            if self.usage[id] == nil { messages.append(timestamp) }
            self.usage[id] = MessageUsage(timestamp: timestamp, model: model, split: split)
            self.model = model
            context = split.input + split.cacheRead + split.cacheWrite
        }
    }

    private static func int(_ value: Any?) -> Int {
        switch value {
        case let number as Int: number
        case let number as NSNumber: number.intValue
        default: 0
        }
    }
}

enum TranscriptScan {
    static var projectsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// Brings every transcript touched since `since` (plus `extra`, the open
    /// sessions' files) up to date. Unchanged files keep their state untouched.
    static func refresh(
        _ states: [String: TranscriptState],
        root: URL = projectsRoot,
        since: Date,
        extra: [String] = [],
        fileManager: FileManager = .default
    ) -> [String: TranscriptState] {
        var paths = Set(extra)
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        if let walker = fileManager.enumerator(at: root, includingPropertiesForKeys: keys) {
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                let modified = (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
                if modified >= since { paths.insert(url.path) }
            }
        }
        var next: [String: TranscriptState] = [:]
        for path in paths {
            next[path] = advance(states[path] ?? TranscriptState(), path: path, fileManager: fileManager)
        }
        return next
    }

    static func advance(_ state: TranscriptState, path: String, fileManager: FileManager = .default) -> TranscriptState {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value
        else { return state }
        var state = size < state.offset ? TranscriptState() : state
        state.modified = attributes[.modificationDate] as? Date ?? .distantPast
        guard size > state.offset, let handle = FileHandle(forReadingAtPath: path) else { return state }
        defer { try? handle.close() }
        try? handle.seek(toOffset: state.offset)
        guard let data = try? handle.readToEnd(), let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else {
            return state
        }
        // A line still being written stays for the next pass.
        let complete = data[data.startIndex...lastNewline]
        state.consume(Data(complete))
        state.offset += UInt64(complete.count)
        return state
    }

    /// Finds `<session>.jsonl` under the projects folder.
    static func path(sessionID: String, root: URL = projectsRoot, fileManager: FileManager = .default) -> String? {
        guard let folders = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return nil }
        for folder in folders {
            let candidate = folder.appendingPathComponent("\(sessionID).jsonl").path
            if fileManager.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Claude Code keeps a project's transcripts in a folder named after the
    /// cwd with every non-alphanumeric character turned into "-".
    static func folder(cwd: String, root: URL = projectsRoot) -> URL {
        let name = String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        return root.appendingPathComponent(name, isDirectory: true)
    }

    /// The project's session transcripts, newest first.
    static func recent(cwd: String, root: URL = projectsRoot, fileManager: FileManager = .default) -> [String] {
        let key = URLResourceKey.contentModificationDateKey
        guard let files = try? fileManager.contentsOfDirectory(
            at: folder(cwd: cwd, root: root),
            includingPropertiesForKeys: [key]
        ) else { return [] }
        return files
            .filter { $0.pathExtension == "jsonl" }
            .map { ($0.path, (try? $0.resourceValues(forKeys: [key]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    static func isSubagent(_ path: String) -> Bool {
        path.contains("/subagents/")
    }
}
