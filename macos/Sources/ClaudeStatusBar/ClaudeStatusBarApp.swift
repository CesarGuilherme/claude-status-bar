import AppKit
import SwiftUI

@main
enum Bootstrap {
    static func main() {
        if CommandLine.arguments.contains("--dump") {
            let semaphore = DispatchSemaphore(value: 0)
            // Detached: waiting on the semaphore below blocks the main thread,
            // and a main-actor task would never get to run.
            Task.detached {
                await Dump.run()
                fflush(stdout)
                semaphore.signal()
            }
            semaphore.wait()
            return
        }
        // No SwiftUI App scene: a Settings scene was opening a window on its own.
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.delegate = AppKeep.controller
        NSApplication.shared.run()
    }
}

@MainActor
private enum AppKeep {
    static let controller = StatusBarController()
}

/// MenuBarExtra draws its label into a template image, which clips the meters and
/// throws away Liquid Glass. A real status-item view keeps the glass chip.
@MainActor
final class StatusBarController: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var outsideClick: Any?
    private var poppingMenu = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Trace.reset()
        let item = NSStatusBar.system.statusItem(withLength: 96)
        statusItem = item
        guard let button = item.button else {
            Trace.log("no status button")
            return
        }
        button.image = nil
        button.title = ""
        let host = PassThroughHost(rootView: MenuBarLabel(model: model))
        host.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            host.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        ])
        button.setAccessibilityLabel(L10n.tr("Claude usage"))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.target = self
        button.action = #selector(statusClick)
        installOutsideClick()
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]) { event in
            Trace.log("local \(event.type.rawValue) window=\(String(describing: type(of: event.window))) loc=\(NSStringFromPoint(event.locationInWindow))")
            return event
        }
        Trace.log("launch before close \(Self.describe(button: button, host: host)) windows=\(Self.describeWindows(panel: panel))")
        closeStrayWindows()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.closeStrayWindows()
            Trace.log("launch async \(Self.describe(button: button, host: host)) windows=\(Self.describeWindows(panel: self.panel))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            self.closeStrayWindows()
            Trace.log("launch +0.6 \(Self.describe(button: button, host: host)) windows=\(Self.describeWindows(panel: self.panel))")
        }
    }

    @objc private func statusClick() {
        let event = NSApp.currentEvent
        Trace.log("statusClick type=\(String(describing: event?.type.rawValue))")
        // A double-click would open and at once close the panel; only the first click counts.
        if let event, event.type == .leftMouseUp, event.clickCount > 1 { return }
        let rightClick = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if rightClick {
            showQuitMenu()
        } else {
            togglePanel()
        }
    }

    /// Right-click keeps the left-click panel. Assigning `statusItem.menu` for good
    /// would replace that click, so the menu is only attached for this popup.
    private func showQuitMenu() {
        guard !poppingMenu else { return }
        poppingMenu = true
        let menu = StatusMenus.quitMenu(target: self, action: #selector(quit))
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
        poppingMenu = false
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func closeStrayWindows() {
        // The status item lives in an NSStatusBarWindow. Closing it leaves the
        // icon drawn but its button stops getting clicks.
        for window in NSApp.windows where window !== panel && !String(describing: type(of: window)).contains("StatusBar") {
            Trace.log("close stray \(type(of: window)) frame=\(NSStringFromRect(window.frame))")
            window.close()
        }
    }

    @objc private func togglePanel() {
        if panel?.isVisible == true {
            Trace.log("toggle orderOut")
            panel?.orderOut(nil)
            return
        }
        let panel = panel ?? Self.makePanel(model: model)
        self.panel = panel
        guard let button = statusItem?.button, let window = button.window else {
            Trace.log("toggle abort button=\(statusItem?.button != nil) window=\(statusItem?.button?.window != nil)")
            return
        }
        Trace.log("toggle buttonFrame=\(NSStringFromRect(window.convertToScreen(button.convert(button.bounds, to: nil)))) buttonBounds=\(NSStringFromRect(button.bounds))")
        Self.size(panel)
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let size = panel.frame.size
        // The status item can sit on any display, including one left of the
        // main screen (negative x), so clamp to the button's own screen.
        let screen = (window.screen ?? NSScreen.main)?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = min(max(screen.minX + 8, anchor.midX - size.width / 2), screen.maxX - size.width - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: anchor.minY - size.height - 4))
        panel.orderFrontRegardless()
        Trace.log("toggle shown frame=\(NSStringFromRect(panel.frame)) visible=\(panel.isVisible) opaque=\(panel.isOpaque) alpha=\(panel.alphaValue)")
    }

    /// PopoverView's width and its maximum height; longer content scrolls.
    static let panelSize = NSSize(width: 352, height: 640)

    /// The panel is a ScrollView, which has no ideal height: fittingSize is 0
    /// and a host sized from it is 1pt tall and draws nothing. Use a fixed size.
    static func size(_ panel: NSPanel) {
        panel.setContentSize(panelSize)
        panel.contentView?.frame = NSRect(origin: .zero, size: panelSize)
    }

    static func makePanel(model: AppModel) -> NSPanel {
        let host = NSHostingView(rootView: PopoverView(model: model))
        host.sizingOptions = []
        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // A transparent window shadows every opaque shape, which outlines each
        // glass card in dark. The glass draws its own edge.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = host
        return panel
    }

    private func installOutsideClick() {
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, panel.isVisible else { return }
                let point = NSEvent.mouseLocation
                let buttonFrame = self.statusItem?.button?.window?.convertToScreen(
                    self.statusItem?.button?.convert(self.statusItem?.button?.bounds ?? .zero, to: nil) ?? .zero
                ) ?? .zero
                if !panel.frame.contains(point), !buttonFrame.contains(point) {
                    panel.orderOut(nil)
                }
            }
        }
    }

    private static func describe(button: NSStatusBarButton, host: NSView) -> String {
        let window = button.window
        return "button=\(NSStringFromRect(button.bounds)) host=\(NSStringFromRect(host.frame)) window=\(String(describing: window.map { type(of: $0) })) windowFrame=\(window.map { NSStringFromRect($0.frame) } ?? "nil")"
    }

    private static func describeWindows(panel: NSPanel?) -> String {
        NSApp.windows.map { "\(type(of: $0)):\(NSStringFromRect($0.frame))" }.joined(separator: " | ")
    }
}

private enum Trace {
    static func reset() {
        FileManager.default.createFile(atPath: "/tmp/claude-status-bar.log", contents: Data())
    }

    static func log(_ message: String) {
        let line = "\(String(format: "%.3f", Date().timeIntervalSince1970)) \(message)\n"
        guard let data = line.data(using: .utf8),
              let handle = FileHandle(forWritingAtPath: "/tmp/claude-status-bar.log") else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    }
}

/// A borderless panel can't become key by default, so the sign-in code field
/// took no typing or paste. The app has no Edit menu either (it is a menu bar
/// accessory), so the standard edit shortcuts are routed here.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let action: Selector? = switch (event.modifierFlags.intersection(.deviceIndependentFlagsMask), event.charactersIgnoringModifiers) {
        case (.command, "x"): #selector(NSText.cut(_:))
        case (.command, "c"): #selector(NSText.copy(_:))
        case (.command, "v"): #selector(NSText.paste(_:))
        case (.command, "a"): #selector(NSText.selectAll(_:))
        case (.command, "z"): Selector(("undo:"))
        case ([.command, .shift], "z"), ([.command, .shift], "Z"): Selector(("redo:"))
        default: nil
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

private final class PassThroughHost<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Quit is a real menu, available whether or not the user has signed in.
enum StatusMenus {
    static var quitTitle: String { L10n.tr("Quit") }

    static func quitMenu(target: AnyObject, action: Selector) -> NSMenu {
        let menu = NSMenu(title: "Claude Status Bar")
        let item = NSMenuItem(title: quitTitle, action: action, keyEquivalent: "q")
        item.target = target
        menu.addItem(item)
        return menu
    }
}

enum Dump {
    static func run() async {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let processes = ProcessProbe.snapshot()
        let claudeText = (try? String(contentsOf: CostLog.defaultURL, encoding: .utf8)) ?? ""
        let costs = SessionLogic.parseCosts(claudeText)
        let cache = StatsCache.load()
        let started = Date()
        let transcripts = TranscriptScan.refresh(
            [:],
            since: cache?.cutoff() ?? Calendar.current.startOfDay(for: Date()),
            extra: SessionLogic.transcriptPaths(processes: processes)
        )
        let scanSeconds = Date().timeIntervalSince(started)
        let sessions = SessionLogic.attach(
            SessionLogic.sessions(processes: processes, costs: costs),
            transcripts: transcripts
        )
        await ExchangeRates.refreshIfStale()
        let brlText = try? String(contentsOf: home.appendingPathComponent(".claude/.usd_brl"), encoding: .utf8)
        let exchange = Exchange.current(brlText: brlText, rates: ExchangeRates.load())
        let totals = OpenTotals.make(sessions)

        print("language \(L10n.language) region=\(Locale.current.region?.identifier ?? "-") sample=\(L10n.tr("Open at Login")) | \(L10n.tr("Longest streak")) | \(Money.cost(usd: 1, exchange: exchange)) | \(Money.tokens(7_033_931_207))")
        print("sessions \(sessions.count)")
        for session in sessions {
            let cost = session.costUSD.map { String(format: "usd=%.4f", $0) } ?? "usd=-"
            let tokens = session.tokens.map { "tokens=\($0)" } ?? "tokens=-"
            let context = session.context.map { String(format: "ctx=%.0f%%", $0) } ?? "ctx=-"
            let idle = session.lastActivity.map { "idle=\(Int(Date().timeIntervalSince($0)))s" } ?? "idle=-"
            print("- \(session.harness.title) model=\(session.model) project=\(session.project) elapsed=\(session.elapsed) \(cost) \(tokens) \(context) \(idle) working=\(session.isWorking())")
        }
        print("totals sessions=\(totals.sessions) claude_usd=\(String(format: "%.4f", totals.claudeUSD)) currency=\(exchange.currency) rate=\(String(format: "%.4f", exchange.rate)) open=\(Money.cost(usd: totals.claudeUSD, exchange: exchange)) today=\(Money.cost(usd: CostLog.spentUSD(costs, since: Calendar.current.startOfDay(for: Date())), exchange: exchange))")
        print("transcripts scanned=\(transcripts.count) seconds=\(String(format: "%.2f", scanSeconds)) cache=\(cache != nil) cutoff=\(cache?.cutoff().formatted(date: .numeric, time: .omitted) ?? "-")")
        let claudeInput = HistoryLog.claudeInput(cache: cache, transcripts: transcripts, costsText: claudeText)
        let now = Date()
        for range in HistoryRange.allCases {
            let snap = HistoryLog.snapshot(input: claudeInput, range: range, now: now)
            let busiest = snap.busiestDay?.formatted(.dateTime.day().month(.abbreviated)) ?? "-"
            print("history \(range.rawValue) tokens=\(Money.tokens(snap.totalTokens)) sessions=\(snap.sessions) active=\(snap.activeDays)/\(snap.spanDays) favorite=\(ModelMatch.displayName(snap.favoriteModel)) busiest=\(busiest) longest=\(HistoryLog.duration(snap.longestSession)) streak=\(snap.currentStreak)/\(snap.longestStreak) split=\(snap.splitKnown)")
            if range == .all {
                for share in snap.shares {
                    print("  model \(ModelMatch.displayName(share.model)) \(String(format: "%.1f%%", share.percent)) in=\(Money.tokens(share.input)) out=\(Money.tokens(share.output)) cache_read=\(Money.tokens(share.cacheRead)) cache_write=\(Money.tokens(share.cacheWrite))")
                }
            }
        }
        fflush(stdout)

        let credentials: OAuthCredentials?
        if let app = CredentialStore.loadApp(), !app.isExpired() {
            credentials = app
        } else if let claude = CredentialStore.loadClaudeCode(), !claude.isExpired() {
            credentials = claude
        } else {
            credentials = nil
        }

        guard let credentials else {
            print("usage auth=missing")
            return
        }
        print("usage auth=\(credentials.source.rawValue)")
        do {
            let usage = try await UsageClient.fetch(credentials)
            let rows = ModelMatch.pinLive(usage.perModelWeekly(), liveModelIDs: sessions.map(\.model))
            print("usage five_hour=\(usage.fiveHour?.utilization.map { String($0) } ?? "-") reset=\(ResetClock.hourMinute(usage.fiveHour?.resetsAt) ?? "-")")
            print("usage seven_day=\(usage.sevenDay?.utilization.map { String($0) } ?? "-")")
            if let extra = usage.extraUsage {
                print("usage extra_enabled=\(extra.isEnabled) extra_usd=\(extra.usedUSD.map { String($0) } ?? "-") extra_limit=\(extra.monthlyUSD.map { String($0) } ?? "-")")
            }
            if rows.isEmpty {
                print("model none")
            }
            for row in rows {
                print("model \(row.displayName) percent=\(row.percent) live=\(row.live) reset=\(ResetClock.hourMinute(row.resetsAt) ?? "-")")
            }
        } catch {
            print("usage error=\(UsageClient.message(error, source: credentials.source))")
        }
    }
}
