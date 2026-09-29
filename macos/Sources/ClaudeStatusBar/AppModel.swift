import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    var sessions: [LiveSession] = []
    var usage: UsageResponse?
    var modelRows: [PerModelUsage] = []
    var brlRate: Double = Money.fallbackBRL
    var lastUpdated: Date?
    var status: String?
    var pollingMinutes: Int = 5
    var authSource: OAuthCredentials.Source?
    var awaitingCode = false
    var oauthCode = ""
    var busyAuth = false
    var opensAtLogin = false
    var loginNote: String?
    var claudeHistory = HistoryInput()
    var todayUSD: Double = 0

    private var transcripts: [String: TranscriptState] = [:]
    private var pendingOAuth: OAuthFlow.Pending?
    private var loopsStarted = false
    private var sessionLoop: Task<Void, Never>?
    private var usageLoop: Task<Void, Never>?

    var totals: OpenTotals { OpenTotals.make(sessions) }

    init(startLoops: Bool = true) {
        let stored = UserDefaults.standard.integer(forKey: "pollingMinutes")
        if [5, 15, 30].contains(stored) { pollingMinutes = stored }
        opensAtLogin = LoginLaunch.isBundled
            ? LoginLaunch.appServiceStatus == .enabled
            : LoginLaunch.isInstalled(home: FileManager.default.homeDirectoryForCurrentUser)
        if startLoops { start() }
    }

    func setOpensAtLogin(_ enabled: Bool) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if LoginLaunch.isBundled {
            do {
                try LoginLaunch.setAppService(enabled)
                // An agent left by an earlier `swift run` build would start a second copy.
                if enabled, LoginLaunch.isInstalled(home: home) { try? LoginLaunch.remove(home: home) }
                loginNote = LoginLaunch.appServiceStatus == .requiresApproval
                    ? L10n.tr("Approve in System Settings › General › Login Items.")
                    : nil
            } catch {
                loginNote = L10n.tr("Couldn't change opening at login.")
            }
            opensAtLogin = LoginLaunch.appServiceStatus == .enabled
            return
        }
        do {
            if enabled {
                guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath().path else {
                    loginNote = L10n.tr("Couldn't find the executable.")
                    opensAtLogin = false
                    return
                }
                try LoginLaunch.install(executable: executable, home: home)
                loginNote = L10n.tr("Takes effect at the next login.")
            } else {
                try LoginLaunch.remove(home: home)
                LoginLaunch.unloadIfLoaded()
                loginNote = nil
            }
            opensAtLogin = LoginLaunch.isInstalled(home: home)
        } catch {
            opensAtLogin = LoginLaunch.isInstalled(home: home)
            loginNote = L10n.tr("Couldn't change opening at login.")
        }
    }

    func start() {
        guard !loopsStarted else { return }
        loopsStarted = true
        sessionLoop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshSessions()
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
        restartUsageLoop()
    }

    func setPolling(_ minutes: Int) {
        guard [5, 15, 30].contains(minutes) else { return }
        pollingMinutes = minutes
        UserDefaults.standard.set(minutes, forKey: "pollingMinutes")
        restartUsageLoop()
    }

    func refreshSessions() async {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let costURL = CostLog.defaultURL
        let rateURL = home.appendingPathComponent(".claude/.usd_brl")
        let previous = transcripts
        let snapshot = await Task.detached(priority: .utility) {
            let processes = ProcessProbe.snapshot()
            let claudeText = (try? String(contentsOf: costURL, encoding: .utf8)) ?? ""
            let costs = SessionLogic.parseCosts(claudeText)
            let cache = StatsCache.load()
            let since = cache?.cutoff() ?? Calendar.current.startOfDay(for: Date())
            let scanned = TranscriptScan.refresh(
                previous,
                since: since,
                extra: SessionLogic.transcriptPaths(processes: processes)
            )
            let sessions = SessionLogic.attach(
                SessionLogic.sessions(processes: processes, costs: costs),
                transcripts: scanned
            )
            let rateText = try? String(contentsOf: rateURL, encoding: .utf8)
            return (
                sessions,
                Money.rate(contents: rateText),
                HistoryLog.claudeInput(cache: cache, transcripts: scanned, costsText: claudeText),
                scanned,
                CostLog.spentUSD(costs, since: Calendar.current.startOfDay(for: Date()))
            )
        }.value
        sessions = snapshot.0
        brlRate = snapshot.1
        claudeHistory = snapshot.2
        transcripts = snapshot.3
        todayUSD = snapshot.4
        rebuildRows()
    }

    func refreshUsage() async {
        if var app = CredentialStore.loadApp() {
            if app.isExpired() {
                do {
                    app = try await OAuthFlow.refresh(app)
                    try CredentialStore.saveApp(app)
                } catch UsageError.transport {
                    status = UsageClient.message(UsageError.transport, source: .app)
                    return
                } catch {
                    CredentialStore.deleteApp()
                    appLoginFailed()
                }
            }
            if let current = CredentialStore.loadApp(), !current.isExpired() {
                await apply(current)
                return
            }
        }

        // The Keychain read can wait on an access prompt; keep it off the main thread.
        let claudeCode = await Task.detached(priority: .utility) { CredentialStore.loadClaudeCode() }.value
        if let claude = claudeCode, !claude.isExpired() {
            await apply(claude)
            return
        }

        authSource = nil
        if status == nil {
            status = L10n.tr("Sign in to see the account quota.")
        }
    }

    func beginSignIn() {
        let pending = OAuthFlow.begin()
        pendingOAuth = pending
        awaitingCode = true
        status = nil
        NSWorkspace.shared.open(pending.url)
    }

    func submitCode() async {
        guard let pending = pendingOAuth else { return }
        busyAuth = true
        defer { busyAuth = false }
        do {
            let credentials = try await OAuthFlow.exchange(rawCode: oauthCode, pending: pending)
            try CredentialStore.saveApp(credentials)
            awaitingCode = false
            oauthCode = ""
            pendingOAuth = nil
            await refreshUsage()
        } catch {
            status = L10n.tr("Couldn't exchange the code. Paste the whole code#state.")
        }
    }

    func forgetAppLogin() {
        CredentialStore.deleteApp()
        usage = nil
        modelRows = []
        authSource = nil
        lastUpdated = nil
        status = nil
        Task { await refreshUsage() }
    }

    private func apply(_ credentials: OAuthCredentials) async {
        do {
            let response = try await UsageClient.fetch(credentials)
            usage = response
            authSource = credentials.source
            lastUpdated = Date()
            status = nil
            rebuildRows()
        } catch UsageError.unauthorized where credentials.source == .app {
            do {
                let refreshed = try await OAuthFlow.refresh(credentials)
                try CredentialStore.saveApp(refreshed)
                usage = try await UsageClient.fetch(refreshed)
                authSource = .app
                lastUpdated = Date()
                status = nil
                rebuildRows()
            } catch {
                CredentialStore.deleteApp()
                status = UsageClient.message(error, source: .app)
                authSource = nil
            }
        } catch {
            status = UsageClient.message(error, source: credentials.source)
        }
    }

    private func appLoginFailed() {
        status = L10n.tr("This app's login expired.")
    }

    private func rebuildRows() {
        let claudeModels = sessions.map(\.model)
        modelRows = ModelMatch.pinLive(usage?.perModelWeekly() ?? [], liveModelIDs: claudeModels)
    }

    private func restartUsageLoop() {
        usageLoop?.cancel()
        let interval = UInt64(pollingMinutes) * 60 * 1_000_000_000
        usageLoop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshUsage()
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }
}
