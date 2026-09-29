import AppKit
import Foundation
import SwiftUI
import Testing
@testable import ClaudeStatusBar

struct UsageModelTests {
    @Test func limitsSupersedeFixedOpusAndSonnet() throws {
        let url = try #require(Bundle.module.url(forResource: "usage-limits", withExtension: "json"))
        let usage = try JSONDecoder().decode(UsageResponse.self, from: Data(contentsOf: url))
        let rows = usage.perModelWeekly()
        let names = rows.map(\.displayName)
        #expect(names.filter { $0 == "Opus" }.count == 1)
        #expect(names.contains("Sonnet"))
        #expect(!names.contains("Ignored"))
        #expect(rows.first { $0.displayName == "Opus" }?.percent == 88)
        #expect(rows.first { $0.displayName == "Sonnet" }?.percent == 12)
        #expect(usage.extraUsage?.usedUSD == 12.4)
        #expect(usage.extraUsage?.monthlyUSD == 50)
    }

    @Test func surfacedLimitKeepsAccountOpus() throws {
        let json = """
        {"seven_day_opus":{"utilization":91,"resets_at":"2026-10-06T00:00:00Z"},
         "limits":[{"kind":"weekly_scoped","percent":40,"group":"code",
           "scope":{"model":{"display_name":"Opus"},"surface":{"display_name":"Claude Code"}}}]}
        """.data(using: .utf8)!
        let usage = try JSONDecoder().decode(UsageResponse.self, from: json)
        let names = usage.perModelWeekly().map(\.displayName)
        #expect(names.contains("Opus (Claude Code)"))
        #expect(names.contains("Opus"))
    }

    @Test func duplicateNamesGainTheirGroup() throws {
        let json = """
        {"limits":[
          {"kind":"weekly_scoped","percent":10,"group":"a","scope":{"model":{"display_name":"Opus"}}},
          {"kind":"weekly_scoped","percent":20,"group":"b","scope":{"model":{"display_name":"Opus"}}}
        ]}
        """.data(using: .utf8)!
        let usage = try JSONDecoder().decode(UsageResponse.self, from: json)
        let names = Set(usage.perModelWeekly().map(\.displayName))
        #expect(names.contains("Opus — a"))
        #expect(names.contains("Opus — b"))
    }
}

struct ModelMatchTests {
    @Test func opusIDsPinTheOpusRow() {
        let rows = [
            PerModelUsage(id: "s", displayName: "Sonnet", percent: 10),
            PerModelUsage(id: "o", displayName: "Opus", percent: 90),
        ]
        for id in ["claude-opus-5-5", "opusplan"] {
            let pinned = ModelMatch.pinLive(rows, liveModelIDs: [id])
            #expect(pinned[0].displayName == "Opus")
            #expect(pinned[0].live)
            #expect(!pinned[1].live)
        }
        #expect(ModelMatch.hottestLivePercent(ModelMatch.pinLive(rows, liveModelIDs: ["claude-opus-5-5"])) == 90)
    }

    @Test func grokTicksDoNotBecomeReais() {
        #expect(GrokCost.usd(ticks: 36_304_880_400) == nil)
    }

    @Test func moneyUsesCachedRateAndBrazilianReais() {
        #expect(Money.rate(contents: nil) == 5.40)
        #expect(Money.rate(contents: " 5.71 \n") == 5.71)
        #expect(Money.rate(contents: "nope") == 5.40)
        let label = Money.brl(usd: 2, rate: 5.40)
        #expect(label.contains("10,80"))
        #expect(label.contains("R$"))
        #expect(Money.tokens(12_926_641) == "12,9 mi")
    }

    @Test func resetClockUsesTheGivenTimeZone() {
        let clock = ResetClock.hourMinute("2026-09-29T18:00:00Z", timeZone: TimeZone(secondsFromGMT: 0)!)
        #expect(clock == "18:00")
        let saoPaulo = ResetClock.hourMinute(
            "2026-09-29T18:00:00Z",
            timeZone: TimeZone(identifier: "America/Sao_Paulo")!
        )
        #expect(saoPaulo == "15:00")
    }
}

struct SessionTests {
    @Test func resumeFlagWinsOverOpenFiles() {
        let command = "/usr/bin/claude --resume 5de99736-0fde-4c7d-bc58-ad844bebbb13 --debug x"
        let id = SessionLogic.sessionID(command: command, openJSONL: [
            "/Users/me/.claude/projects/proj/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.jsonl"
        ])
        #expect(id == "5de99736-0fde-4c7d-bc58-ad844bebbb13")
    }

    @Test func missingTranscriptStillListsTheProcess() throws {
        let process = ProcessSnapshot(
            pid: 7,
            elapsed: "01:02",
            command: "/opt/homebrew/bin/claude",
            cwd: "/tmp/proj",
            openJSONL: [],
            envModel: "opusplan"
        )
        let rows = SessionLogic.sessions(processes: [process], costs: []) { _ in nil }
        #expect(rows.count == 1)
        #expect(rows[0].harness == .claude)
        #expect(rows[0].model == "opusplan")
        #expect(rows[0].project == "proj")
        #expect(rows[0].costUSD == nil)
    }

    @Test func settingsModelBeatsGenericEnvBest() {
        let command = #"/Xcode/CodingAssistant/claude/claude --settings {"env":{"ANTHROPIC_MODEL":"opusplan"}}"#
        let process = ProcessSnapshot(pid: 4, elapsed: "01:00", command: command, cwd: "/work/app", openJSONL: [], envModel: "best")
        let rows = SessionLogic.sessions(processes: [process], costs: []) { _ in nil }
        #expect(rows[0].harness == .xcode)
        #expect(rows[0].model == "opusplan")
    }

    @Test func xcodePathIsItsOwnHarness() {
        let command = "/Users/me/Library/Developer/Xcode/CodingAssistant/Agents/XcodeVersions/claude/claude --resume 5de99736-0fde-4c7d-bc58-ad844bebbb13"
        #expect(SessionLogic.classify(command) == .xcode)
    }

    @Test func costsPickTheLatestRowBecauseRowsAreRunningTotals() throws {
        let url = try #require(Bundle.module.url(forResource: "costs-snippet", withExtension: "jsonl"))
        let costs = SessionLogic.parseCosts(try String(contentsOf: url, encoding: .utf8))
        let process = ProcessSnapshot(
            pid: 3,
            elapsed: "00:10",
            command: "claude --resume aaa",
            cwd: "/work/mysql",
            openJSONL: [],
            envModel: nil
        )
        // --resume aaa is not a uuid, so the session id comes from nowhere and cost stays nil.
        // Feed the uuid through the resume flag.
        let withID = ProcessSnapshot(
            pid: 3,
            elapsed: "00:10",
            command: "claude --resume 00000000-0000-0000-0000-0000000000aa",
            cwd: "/work/mysql",
            openJSONL: [],
            envModel: nil
        )
        _ = process
        let tagged = costs.map { event in
            CostEvent(
                sessionID: event.sessionID == "aaa" ? "00000000-0000-0000-0000-0000000000aa" : event.sessionID,
                model: event.model,
                usd: event.usd,
                timestamp: event.timestamp
            )
        }
        let rows = SessionLogic.sessions(processes: [withID], costs: tagged) { _ in nil }
        #expect(rows[0].model == "claude-opus-5-5")
        #expect(rows[0].costUSD == 2.5)
    }

    @Test func spendSinceMidnightSubtractsWhatTheSessionHadBefore() {
        let costs = [
            CostEvent(sessionID: "a", model: "m", usd: 1.0, timestamp: "2026-09-28T20:00:00Z"),
            CostEvent(sessionID: "a", model: "m", usd: 1.6, timestamp: "2026-09-29T10:00:00Z"),
            CostEvent(sessionID: "b", model: "m", usd: 0.4, timestamp: "2026-09-29T11:00:00Z"),
            CostEvent(sessionID: "c", model: "m", usd: 9.0, timestamp: "2026-09-27T11:00:00Z"),
        ]
        let midnight = HistoryLog.parseDate("2026-09-29T00:00:00Z")!
        #expect(abs(CostLog.spentUSD(costs, since: midnight) - 1.0) < 0.0001)
    }

    @Test func quietProcessTakesTheNewestUnclaimedTranscriptOfItsFolder() {
        let resumed = ProcessSnapshot(pid: 1, elapsed: "1", command: "claude --resume 11111111-1111-1111-1111-111111111111", cwd: "/p", openJSONL: [], envModel: nil)
        let quiet = ProcessSnapshot(pid: 2, elapsed: "1", command: "claude", cwd: "/p", openJSONL: [], envModel: nil)
        let guessed = SessionLogic.guessTranscripts([resumed, quiet]) { _ in
            ["/x/11111111-1111-1111-1111-111111111111.jsonl", "/x/22222222-2222-2222-2222-222222222222.jsonl"]
        }
        #expect(guessed[0].openJSONL.isEmpty)
        #expect(guessed[1].openJSONL == ["/x/22222222-2222-2222-2222-222222222222.jsonl"])
        #expect(TranscriptScan.folder(cwd: "/Volumes/SSD_CESAR/Developer/claude_status_bar", root: URL(fileURLWithPath: "/r")).lastPathComponent
            == "-Volumes-SSD-CESAR-Developer-claude-status-bar")
    }

    @Test func transcriptCountsEachMessageOnceAndKeepsTheLastContext() throws {
        let lines = """
        {"type":"user","timestamp":"2026-09-29T10:00:00.000Z","sessionId":"s1","message":{"role":"user"}}
        {"type":"assistant","timestamp":"2026-09-29T10:00:05.000Z","sessionId":"s1","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200}}}
        {"type":"assistant","timestamp":"2026-09-29T10:00:06.000Z","sessionId":"s1","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":10,"output_tokens":7,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200}}}
        {"type":"assistant","timestamp":"2026-09-29T10:01:00.000Z","sessionId":"s1","message":{"id":"m2","model":"claude-opus-5-5","usage":{"input_tokens":2,"output_tokens":3,"cache_read_input_tokens":250000,"cache_creation_input_tokens":0}}}
        {"type":"summary","summary":"ignored"}
        {"type":"assistant","timestamp":"2026-09-29T10:02
        """
        var state = TranscriptState()
        state.consume(Data(lines.utf8))
        #expect(state.sessionID == "s1")
        #expect(state.usage.count == 2)
        #expect(state.total.output == 10)
        #expect(state.total.cacheRead == 251_000)
        #expect(state.messages.count == 3)
        #expect(state.context == 250_002)
        #expect(ModelMatch.contextWindow(used: 250_002) == 1_000_000)
        #expect(ModelMatch.contextWindow(used: 1_210) == 200_000)

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(lines.utf8).write(to: file)
        let first = TranscriptScan.advance(TranscriptState(), path: file.path)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(":00.000Z\",\"sessionId\":\"s1\",\"message\":{\"id\":\"m3\",\"model\":\"claude-opus-5-5\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n".utf8))
        try handle.close()
        // The cut line from the first pass is read whole on the second.
        let second = TranscriptScan.advance(first, path: file.path)
        #expect(first.usage.count == 2)
        #expect(second.usage.count == 3)
        #expect(second.total.output == 11)
    }

    @Test func processLineParsesPidElapsedAndTheRest() {
        let parsed = SessionLogic.parseProcessLine("  24237 05:33 grok")
        #expect(parsed?.pid == 24237)
        #expect(parsed?.elapsed == "05:33")
        #expect(parsed?.command == "grok")
        let long = SessionLogic.parseProcessLine("20433 1-02:03:04 /usr/bin/claude --resume abc")
        #expect(long?.elapsed == "1-02:03:04")
        #expect(long?.command == "/usr/bin/claude --resume abc")
    }

    @Test func grokSessionCarriesModelAndTokens() {
        let process = ProcessSnapshot(
            pid: 9,
            elapsed: "04:00",
            command: "grok",
            cwd: "/Volumes/SSD_CESAR/Developer/claude_status_bar",
            openJSONL: [],
            envModel: nil
        )
        let snap = GrokSnapshot(sessionID: "abc", model: "grok-4.7", tokens: 12_926_641)
        let rows = SessionLogic.sessions(processes: [process], costs: []) { cwd in
            cwd.hasSuffix("claude_status_bar") ? snap : nil
        }
        #expect(rows[0].harness == .grok)
        #expect(rows[0].model == "grok-4.7")
        #expect(rows[0].tokens == 12_926_641)
        #expect(rows[0].project == "claude_status_bar")
        #expect(rows[0].costUSD == nil)
    }

    @Test func rollsUpOpenSessionsByModel() {
        let sessions = [
            LiveSession(id: "1", harness: .claude, usageKey: "a", model: "claude-opus-5-5", project: "a", elapsed: "1", costUSD: 1, tokens: nil),
            LiveSession(id: "2", harness: .xcode, usageKey: "a", model: "claude-opus-5-5", project: "a", elapsed: "1", costUSD: 1, tokens: nil),
            LiveSession(id: "3", harness: .grok, usageKey: "g", model: "grok-4.7", project: "b", elapsed: "1", costUSD: nil, tokens: 1000),
        ]
        let rows = ModelRollup.make(sessions)
        #expect(rows.map(\.model) == ["claude-opus-5-5", "grok-4.7"])
        #expect(rows[0].sessions == 2)
        #expect(rows[0].costUSD == 1)
        #expect(rows[1].tokens == 1000)
    }

    @Test func xcodeStaysOnTheClaudeTab() {
        let sessions = [
            LiveSession(id: "1", harness: .xcode, usageKey: "x", model: "opusplan", project: "a", elapsed: "1", costUSD: nil, tokens: nil),
            LiveSession(id: "2", harness: .claude, usageKey: "c", model: "claude-opus-5-5", project: "b", elapsed: "1", costUSD: 1, tokens: nil),
            LiveSession(id: "3", harness: .grok, usageKey: "g", model: "grok-4.7", project: "c", elapsed: "1", costUSD: nil, tokens: 10),
        ]
        #expect(sessions.on(.claude).map(\.harness) == [.xcode, .claude])
        #expect(sessions.on(.grok).map(\.harness) == [.grok])
        #expect(OpenTotals.make(sessions.on(.claude)).claudeUSD == 1)
        #expect(OpenTotals.make(sessions.on(.claude)).grokTokens == 0)
        #expect(OpenTotals.make(sessions.on(.grok)).grokTokens == 10)
        #expect(OpenTotals.make(sessions.on(.grok)).sessions == 1)
    }

    @Test func totalsSumClaudeOnceAndGrokTokens() {
        let sessions = [
            LiveSession(id: "1", harness: .claude, usageKey: "same", model: "claude-opus-5-5", project: "a", elapsed: "1", costUSD: 1.5, tokens: nil),
            LiveSession(id: "2", harness: .xcode, usageKey: "same", model: "claude-opus-5-5", project: "a", elapsed: "1", costUSD: 1.5, tokens: nil),
            LiveSession(id: "3", harness: .grok, usageKey: "g", model: "grok-4.7", project: "b", elapsed: "1", costUSD: nil, tokens: 1000),
        ]
        let totals = OpenTotals.make(sessions)
        #expect(totals.sessions == 3)
        #expect(totals.claudeUSD == 1.5)
        #expect(totals.grokTokens == 1000)
    }

    @Test func grokPathMatchesTheOnDiskEncoding() {
        #expect(GrokPath.encode("/Volumes/SSD_CESAR/Developer/claude_status_bar") == "%2FVolumes%2FSSD_CESAR%2FDeveloper%2Fclaude_status_bar")
        #expect(GrokPath.encode("/Volumes/SSD_CESAR/Developer/Diario da Cefaleia") == "%2FVolumes%2FSSD_CESAR%2FDeveloper%2FDiario%20da%20Cefaleia")
    }

    @Test func readsTheNewestGrokSessionForThatCwd() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cwd = "/tmp/proj"
        let base = root.appendingPathComponent(GrokPath.encode(cwd), isDirectory: true)
        let older = base.appendingPathComponent("old")
        let newer = base.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: older, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newer, withIntermediateDirectories: true)
        try """
        {"current_model_id":"grok-old","last_active_at":"2026-09-01T00:00:00Z"}
        """.write(to: older.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)
        try """
        {"current_model_id":"grok-4.7","last_active_at":"2026-09-29T12:00:00Z"}
        """.write(to: newer.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)
        try """
        {"session":{"totalTokens":100,"primaryModelId":"grok-4.7-build"}}
        """.write(to: newer.appendingPathComponent("usage.json"), atomically: true, encoding: .utf8)

        let snap = GrokSessions.load(sessionsRoot: root, cwd: cwd)
        #expect(snap?.sessionID == "new")
        #expect(snap?.model == "grok-4.7")
        #expect(snap?.tokens == 100)
    }
}

struct CredentialTests {
    @Test func parsesClaudeCodeShapeWithoutRefreshingIt() throws {
        let json = """
        {"claudeAiOauth":{"accessToken":"abc","refreshToken":"def","expiresAt":1790715076217,"scopes":["user:profile"]}}
        """.data(using: .utf8)!
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let credentials = try #require(CredentialStore.parseClaudeCode(json, now: now))
        #expect(credentials.accessToken == "abc")
        #expect(credentials.source == .claudeCode)
        #expect(!credentials.isExpired(now: now))
        #expect(credentials.isExpired(now: Date(timeIntervalSince1970: 1_790_715_076)))
    }
}

@MainActor
struct PopoverSmokeTests {
    @Test func popoverLaysOutWithSessionsAndTotals() {
        let model = AppModel(startLoops: false)
        model.sessions = [
            LiveSession(id: "1", harness: .grok, usageKey: "g", model: "grok-4.7", project: "claude_status_bar", elapsed: "05:33", costUSD: nil, tokens: 1000),
        ]
        model.usage = UsageResponse(
            fiveHour: UsageBucket(utilization: 42, resetsAt: "2026-09-29T18:00:00Z"),
            sevenDay: UsageBucket(utilization: 18, resetsAt: nil)
        )
        model.modelRows = ModelMatch.pinLive(model.usage?.perModelWeekly() ?? [], liveModelIDs: ["grok-4.7"])
        let host = NSHostingView(rootView: PopoverView(model: model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 520),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.frame = window.contentView?.bounds ?? .zero
        host.layoutSubtreeIfNeeded()
        #expect(host.bounds.width == 360)
        #expect(model.totals.sessions == 1)
        #expect(model.totals.grokTokens == 1000)
    }

    @Test func loginAgentPointsAtTheBinaryAndRoundTrips() throws {
        let xml = LoginLaunch.plist(executable: "/tmp/Claude & Bar")
        #expect(xml.contains("<string>\(LoginLaunch.label)</string>"))
        #expect(xml.contains("<string>/tmp/Claude &amp; Bar</string>"))
        #expect(xml.contains("<key>RunAtLoad</key>"))

        let home = FileManager.default.temporaryDirectory.appendingPathComponent("login-launch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(!LoginLaunch.isInstalled(home: home))
        try LoginLaunch.install(executable: "/tmp/ClaudeStatusBar", home: home)
        let saved = try String(contentsOf: LoginLaunch.agentURL(home: home), encoding: .utf8)
        #expect(saved.contains("/tmp/ClaudeStatusBar"))
        #expect(LoginLaunch.isInstalled(home: home))
        try LoginLaunch.remove(home: home)
        #expect(!LoginLaunch.isInstalled(home: home))
    }

    @Test func turningLoginOffDoesNotQuitThisProcess() {
        var calls: [[String]] = []
        LoginLaunch.unloadIfLoaded(ownPID: 42) { _, args in
            calls.append(args)
            return "state = running\npid = 42\n"
        }
        #expect(calls.count == 1)
        #expect(calls[0].first == "print")
    }

    @Test func turningLoginOffUnloadsADifferentProcess() {
        var calls: [[String]] = []
        LoginLaunch.unloadIfLoaded(ownPID: 42) { _, args in
            calls.append(args)
            return "state = running\npid = 99\n"
        }
        #expect(calls.count == 2)
        #expect(calls[1].first == "bootout")
    }

    @Test func historyRollsUpDaysModelsAndStreaks() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let text = """
        {"session_id":"s1","model":"claude-sonnet-5","timestamp":"2026-09-28T12:00:00.000Z","input_tokens":100,"output_tokens":40,"cache_read_tokens":10,"cache_write_tokens":5}
        {"session_id":"s1","model":"claude-sonnet-5","timestamp":"2026-09-29T15:00:00.000Z","input_tokens":150,"output_tokens":50,"cache_read_tokens":10,"cache_write_tokens":5}
        {"session_id":"s2","model":"claude-opus-5","timestamp":"2026-09-27T12:00:00.000Z","input_tokens":10,"output_tokens":10,"cache_read_tokens":0,"cache_write_tokens":0}
        """
        let events = HistoryLog.claudeEvents(text: text)
        #expect(events.count == 3)
        let now = try #require(HistoryLog.parseDate("2026-09-29T18:00:00Z"))
        let snapshot = HistoryLog.snapshot(events: events, range: .week, now: now, calendar: calendar)
        #expect(snapshot.totalTokens == 235)
        #expect(snapshot.sessions == 2)
        #expect(snapshot.activeDays == 3)
        #expect(snapshot.spanDays == 7)
        #expect(snapshot.favoriteModel == "claude-sonnet-5")
        #expect(snapshot.currentStreak == 3)
        #expect(snapshot.longestStreak == 3)
        #expect(snapshot.input == 160)
        #expect(snapshot.output == 60)
        #expect(snapshot.cacheRead == 10)
        #expect(snapshot.cacheWrite == 5)
        #expect(snapshot.longestSession == 27 * 3_600)
        #expect(snapshot.models == ["claude-sonnet-5", "claude-opus-5"])
        let sonnet = snapshot.shares.first { $0.model == "claude-sonnet-5" }
        #expect(sonnet?.tokens == 215)
        #expect(HistoryLog.level(tokens: 0, peak: 100) == 0)
        #expect(HistoryLog.level(tokens: 100, peak: 100) == 4)
        #expect(HistoryLog.level(tokens: 10, peak: 100) == 1)
    }

    @Test func statsCacheIsHistoryUntilItsCutoffAndTranscriptsAfter() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let json = """
        {"version":5,"lastComputedDate":"2026-09-28",
         "dailyActivity":[{"date":"2026-09-20","messageCount":40,"sessionCount":2},{"date":"2026-09-27","messageCount":10,"sessionCount":1},{"date":"2026-09-28","messageCount":20,"sessionCount":1}],
         "dailyModelTokens":[{"date":"2026-09-27","tokensByModel":{"claude-opus-5-5":300}},{"date":"2026-09-28","tokensByModel":{"claude-sonnet-5":100}}],
         "modelUsage":{"claude-opus-5-5":{"inputTokens":10,"outputTokens":20,"cacheReadInputTokens":300,"cacheCreationInputTokens":70},
                       "claude-sonnet-5":{"inputTokens":5,"outputTokens":5,"cacheReadInputTokens":80,"cacheCreationInputTokens":10}},
         "longestSession":{"timestamp":"2026-09-20T10:00:00.000Z","duration":7200000},
         "totalSessions":4}
        """.data(using: .utf8)!
        let cache = try #require(StatsCache.parse(json, calendar: calendar))
        #expect(cache.cutoff(calendar: calendar) == HistoryLog.parseDate("2026-09-29T00:00:00Z"))

        // A session that began before the cutoff keeps writing today; only today's
        // messages count, and it is not a new session.
        var old = TranscriptState()
        old.consume(Data("""
        {"type":"assistant","timestamp":"2026-09-28T23:00:00.000Z","sessionId":"old","message":{"id":"a","model":"claude-sonnet-5","usage":{"input_tokens":1000,"output_tokens":1000}}}
        {"type":"assistant","timestamp":"2026-09-29T09:00:00.000Z","sessionId":"old","message":{"id":"b","model":"claude-sonnet-5","usage":{"input_tokens":5,"output_tokens":5}}}

        """.utf8))
        var fresh = TranscriptState()
        fresh.consume(Data("""
        {"type":"user","timestamp":"2026-09-29T12:00:00.000Z","sessionId":"new","message":{}}
        {"type":"assistant","timestamp":"2026-09-29T12:00:01.000Z","sessionId":"new","message":{"id":"c","model":"claude-opus-5-5","usage":{"input_tokens":1,"output_tokens":9,"cache_read_input_tokens":40}}}

        """.utf8))
        let input = HistoryLog.claudeInput(
            cache: cache,
            transcripts: ["/p/old.jsonl": old, "/p/new.jsonl": fresh, "/p/new/subagents/x.jsonl": fresh],
            costsText: "",
            calendar: calendar
        )
        let now = try #require(HistoryLog.parseDate("2026-09-29T18:00:00Z"))
        let all = HistoryLog.snapshot(input: input, range: .all, now: now, calendar: calendar)
        // All-time split: modelUsage (400 + 100) plus today's transcript usage (10 + 50 + 50).
        #expect(all.totalTokens == 610)
        #expect(all.splitKnown)
        #expect(all.favoriteModel == "claude-opus-5-5")
        #expect(all.sessions == 5)
        #expect(all.activeDays == 4)
        #expect(all.spanDays == 10)
        #expect(all.currentStreak == 3)
        #expect(all.longestStreak == 3)
        // "old" ran from 23:00 to 09:00 and outlasts the cached 2h session.
        #expect(all.longestSession == 10 * 3_600)
        #expect(all.busiestDay == HistoryLog.parseDate("2026-09-27T00:00:00Z"))

        let week = HistoryLog.snapshot(input: input, range: .week, now: now, calendar: calendar)
        // Days only: 300 + 100 from the cache, 10 + 50 + 50 from today.
        #expect(week.totalTokens == 510)
        #expect(!week.splitKnown)
        #expect(week.sessions == 3)
        #expect(week.longestSession == 10 * 3_600)
        #expect(!(week.shares.first { $0.model == "claude-opus-5-5" }?.splitKnown ?? true))
        #expect(week.shares.first { $0.model == "claude-sonnet-5" }.map { $0.tokens } == 110)

        #expect(StatsCache.parse(Data("{}".utf8)) == nil)
        let noCache = HistoryLog.claudeInput(cache: nil, transcripts: [:], costsText: "", calendar: calendar)
        #expect(noCache.days.isEmpty)
    }

    @Test func readableModelNames() {
        #expect(ModelMatch.displayName("claude-opus-5-5") == "Opus 5.5")
        #expect(ModelMatch.displayName("claude-sonnet-5") == "Sonnet 5")
        #expect(ModelMatch.displayName("claude-haiku-4-5-20251001") == "Haiku 4.5")
        #expect(ModelMatch.displayName("grok-4.7-build") == "grok-4.7-build")
        #expect(Money.tokens(7_033_931_207) == "7,0 bi")
    }

    @Test func grokTurnsBucketByDayWithoutSummingTwice() throws {
        let json = """
        {"sessionId":"g1","turns":[
          {"endedAt":"2026-09-22T13:14:34.144758+00:00","totalTokens":10,"inputTokens":6,"outputTokens":4,"cachedReadTokens":0,"cacheCreationTokens":0,"primaryModelId":"grok-4.7","costUsdTicks":99},
          {"endedAt":"2026-09-22T18:00:00.000000+00:00","totalTokens":5,"inputTokens":1,"outputTokens":1,"cachedReadTokens":2,"cacheCreationTokens":1,"primaryModelId":"grok-4.7","costUsdTicks":50}
        ]}
        """.data(using: .utf8)!
        let events = HistoryLog.parseGrok(json)
        #expect(events.count == 2)
        #expect(events.map(\.tokens) == [10, 5])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try #require(HistoryLog.parseDate("2026-09-29T00:00:00Z"))
        let snapshot = HistoryLog.snapshot(events: events, range: .all, now: now, calendar: calendar)
        #expect(snapshot.totalTokens == 15)
        #expect(snapshot.sessions == 1)
        #expect(snapshot.activeDays == 1)
        #expect(snapshot.spanDays == 1)
        #expect(snapshot.favoriteModel == "grok-4.7")
        #expect(snapshot.cacheRead == 2)
        #expect(snapshot.cacheWrite == 1)
    }

    @Test func panelHostFillsThePanel() throws {
        let model = AppModel(startLoops: false)
        let panel = StatusBarController.makePanel(model: model)
        // A host shrunk to its (zero) fitting size once left the panel blank.
        panel.contentView?.frame = NSRect(x: 0, y: 0, width: 376, height: 1)
        StatusBarController.size(panel)
        let host = try #require(panel.contentView)
        #expect(host.frame.size == StatusBarController.panelSize)
        #expect(panel.frame.size == StatusBarController.panelSize)
        // Transparent windows shadow each glass card into a dark outline.
        #expect(!panel.hasShadow)
    }

    @Test func quitMenuIsThereForAnyone() {
        let menu = StatusMenus.quitMenu(target: NSApplication.shared, action: #selector(NSApplication.terminate(_:)))
        #expect(menu.items.map(\.title) == [StatusMenus.quitTitle])
        #expect(menu.items.first?.keyEquivalent == "q")
        #expect(menu.items.first?.target != nil)
    }

    @Test func menuBarLabelFitsTheBar() {
        let model = AppModel(startLoops: false)
        model.usage = UsageResponse(
            fiveHour: UsageBucket(utilization: 66, resetsAt: nil),
            sevenDay: UsageBucket(utilization: 5, resetsAt: nil)
        )
        let host = NSHostingView(rootView: MenuBarLabel(model: model))
        let size = host.fittingSize
        #expect(size.width > 40)
        #expect(size.height > 12)
        #expect(size.height < 36)
    }
}
