import AppKit
import SwiftUI

struct PopoverView: View {
    @Bindable var model: AppModel
    @State private var side: SessionSide = .claude
    @Namespace private var glass

    private var shown: [LiveSession] { model.sessions.on(side) }
    private var shownTotals: OpenTotals { OpenTotals.make(shown) }

    var body: some View {
        ScrollView {
            Group {
                if #available(macOS 26, *) {
                    GlassEffectContainer(spacing: 10) {
                        sections
                    }
                    .padding(12)
                    .background(ClearPopoverWindow())
                } else {
                    sections
                        .padding(14)
                }
            }
        }
        .frame(width: 352, alignment: .leading)
        .frame(maxHeight: 640)
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(SessionSide.allCases) { item in
                    GlassPill(
                        title: "\(item.title) \(model.sessions.on(item).count)",
                        selected: side == item
                    ) {
                        withAnimation(.snappy) { side = item }
                    }
                }
            }

            header.glassCard(id: "header", in: glass)
            sessionsSection.glassCard(id: "sessions", in: glass)
            modelSection.glassCard(id: "models", in: glass)
            HistorySection(input: side == .claude ? model.claudeHistory : model.grokHistory)
                .id(side)
                .glassCard(id: "history", in: glass)
            footer
        }
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        if side == .grok {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    SectionLabel(text: "Tokens abertos")
                    Text(Money.tokens(shownTotals.grokTokens))
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                Spacer()
                Text("\(shownTotals.sessions) sessões")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else if let usage = model.usage {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    QuotaRing(
                        title: "5h",
                        percent: usage.fiveHour?.utilization,
                        caption: ResetClock.hourMinute(usage.fiveHour?.resetsAt).map { "↻ \($0)" }
                    )
                    QuotaRing(title: "7d", percent: usage.sevenDay?.utilization, caption: nil)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        SectionLabel(text: "Hoje")
                        Text(Money.brl(usd: model.todayUSD, rate: model.brlRate))
                            .font(.title2.weight(.semibold))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text("abertas \(Money.brl(usd: shownTotals.claudeUSD, rate: model.brlRate))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                extraRow(usage.extraUsage)
            }
            .animation(.snappy, value: usage)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.status ?? "Cota da conta ainda sem leitura.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    SectionLabel(text: "Hoje")
                    Spacer()
                    Text(Money.brl(usd: model.todayUSD, rate: model.brlRate))
                        .monospacedDigit()
                }
                signIn
            }
        }
    }

    // MARK: Sessions

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                SectionLabel(text: "Ao vivo")
                let working = shown.filter { $0.isWorking() }.count
                if working > 0 {
                    Text("\(working) trabalhando")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Threshold.Level.green.color)
                }
            }
            if shown.isEmpty {
                Text("Nenhuma sessão \(side.title) aberta.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(shown) { session in
                    SessionCard(session: session, rate: model.brlRate)
                    if session.id != shown.last?.id {
                        Divider().opacity(0.4)
                    }
                }
            }
        }
    }

    // MARK: Models

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Por modelo")
            if side == .grok {
                localRollup(ModelRollup.make(shown), empty: "Nenhum modelo Grok em uso.")
            } else if model.modelRows.isEmpty {
                localRollup(
                    ModelRollup.make(shown),
                    empty: "Sem janela semanal por modelo.",
                    note: shown.isEmpty ? nil : "A conta não separou a cota por modelo. Abaixo é o uso local destas sessões."
                )
            } else {
                ForEach(model.modelRows) { row in
                    UsageMeter(
                        title: row.displayName,
                        percent: row.percent,
                        trailing: ResetClock.hourMinute(row.resetsAt).map { "↻ \($0)" },
                        live: row.live
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func localRollup(_ rows: [ModelRollup], empty: String, note: String? = nil) -> some View {
        if rows.isEmpty {
            Text(empty)
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(rows) { row in
                HStack {
                    Text(ModelMatch.displayName(row.model))
                        .lineLimit(1)
                    Spacer()
                    Text("\(row.sessions)×")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if row.costUSD > 0 {
                        Text(Money.brl(usd: row.costUSD, rate: model.brlRate))
                            .monospacedDigit()
                    }
                    if row.tokens > 0 {
                        Text(Money.tokens(row.tokens))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .font(.callout)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Toggle(isOn: Binding(
                    get: { model.opensAtLogin },
                    set: { model.setOpensAtLogin($0) }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Abrir com o computador")
                            .font(.callout.weight(.semibold))
                        Text(model.loginNote ?? (model.opensAtLogin ? "Ligado" : "Desligado"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .toggleStyle(ModuleToggleStyle(symbol: "laptopcomputer"))
                .glassCard(id: "login", in: glass, padding: 8, radius: 26, interactive: true)

                quitButton
            }
            HStack(spacing: 8) {
                if model.usage != nil, let status = model.status {
                    Text(status)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let lastUpdated = model.lastUpdated {
                    Text(lastUpdated.formatted(date: .omitted, time: .shortened))
                        .foregroundStyle(.secondary)
                }
                if let source = model.authSource {
                    Text(source == .claudeCode ? "Claude Code" : "login da barra")
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Picker("Atualizar", selection: Binding(
                    get: { model.pollingMinutes },
                    set: { model.setPolling($0) }
                )) {
                    Text("5 min").tag(5)
                    Text("15 min").tag(15)
                    Text("30 min").tag(30)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                if model.authSource == .app {
                    signOutButton
                }
            }
            .font(.caption)
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func extraRow(_ extra: ExtraUsage?) -> some View {
        if let extra, extra.isEnabled {
            HStack {
                Text("Extra")
                    .frame(width: 72, alignment: .leading)
                Text(extraLabel(extra))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .font(.callout)
        }
    }

    private func extraLabel(_ extra: ExtraUsage) -> String {
        switch (extra.usedUSD, extra.monthlyUSD) {
        case let (used?, limit?):
            return "\(Money.usd(used)) / \(Money.usd(limit))"
        case let (used?, nil):
            return Money.usd(used)
        default:
            if let percent = extra.utilization {
                return "\(Int(percent.rounded()))%"
            }
            return "ativo"
        }
    }

    @ViewBuilder
    private var signIn: some View {
        if model.awaitingCode {
            HStack {
                TextField("code#state", text: $model.oauthCode)
                    .textFieldStyle(.roundedBorder)
                Button("OK") {
                    Task { await model.submitCode() }
                }
                .disabled(model.busyAuth || model.oauthCode.isEmpty)
            }
        } else if model.authSource == nil {
            signInButton
        }
    }

    @ViewBuilder
    private var signInButton: some View {
        let button = Button("Entrar com Claude") { model.beginSignIn() }
            .disabled(model.busyAuth)
        if #available(macOS 26, *) {
            button.buttonStyle(.glassProminent)
        } else {
            button
        }
    }

    @ViewBuilder
    private var signOutButton: some View {
        let button = Button("Sair") { model.forgetAppLogin() }
        if #available(macOS 26, *) {
            button.buttonStyle(.glass)
        } else {
            button.buttonStyle(.borderless)
        }
    }

    /// A round module, like the Control Center's single-action buttons.
    private var quitButton: some View {
        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            Image(systemName: "power")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 52, height: 52)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("q")
        .help(StatusMenus.quitTitle)
        .accessibilityLabel(StatusMenus.quitTitle)
        .glassCircle(id: "quit", in: glass)
    }
}

/// Tab pill. The selected one is tinted glass, the rest plain glass.
private struct GlassPill: View {
    var title: String
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(PillGlass(selected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct PillGlass: ViewModifier {
    var selected: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(
                selected ? .regular.tint(StatsPalette.accent.opacity(0.85)).interactive() : .regular.interactive(),
                in: Capsule()
            )
        } else {
            content.background(Capsule().fill(selected ? AnyShapeStyle(StatsPalette.accent) : AnyShapeStyle(.quaternary)))
        }
    }
}

/// Control Center module: a round icon that turns solid white when on, the
/// title, and the state spelled out underneath.
private struct ModuleToggleStyle: ToggleStyle {
    var symbol: String

    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(.snappy) { configuration.isOn.toggle() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(configuration.isOn ? StatsPalette.accent : Color.primary)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle().fill(configuration.isOn ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.primary.opacity(0.12)))
                    )
                configuration.label
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "Ligado" : "Desligado")
    }
}

/// One open session: model, project, state, context use and spend. Click opens
/// the project folder; Option-click opens it in the terminal.
private struct SessionCard: View {
    var session: LiveSession
    var rate: Double

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let working = session.isWorking(now: context.date)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(working ? Threshold.Level.green.color : Color.secondary.opacity(0.5))
                        .symbolEffect(.pulse, isActive: working)
                    Text(ModelMatch.displayName(session.model))
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    if session.harness != .claude {
                        Text(session.harness.title)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                    Spacer(minLength: 6)
                    if let cost = session.costUSD {
                        Text(Money.brl(usd: cost, rate: rate))
                            .font(.callout.monospacedDigit())
                            .contentTransition(.numericText())
                    } else if let tokens = session.tokens {
                        Text("\(Money.tokens(tokens)) tok")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    Text(session.project)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(activity(working: working, now: context.date))
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let percent = session.context {
                    ContextBar(percent: percent, tokens: session.costUSD == nil ? nil : session.tokens)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { open() }
        .help(session.cwd == nil ? "" : "Clique abre a pasta. ⌥-clique abre no terminal.")
    }

    private func activity(working: Bool, now: Date) -> String {
        if working { return "trabalhando · \(session.elapsed)" }
        if let last = session.lastActivity {
            let minutes = Int(now.timeIntervalSince(last) / 60)
            let idle = minutes < 1 ? "agora" : minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h"
            return "ociosa \(idle) · \(session.elapsed)"
        }
        return session.elapsed
    }

    private func open() {
        guard let cwd = session.cwd else { return }
        let folder = URL(fileURLWithPath: cwd, isDirectory: true)
        guard NSEvent.modifierFlags.contains(.option) else {
            NSWorkspace.shared.open(folder)
            return
        }
        let terminals = ["com.github.wez.wezterm", "com.mitchellh.ghostty", "com.googlecode.iterm2", "com.apple.Terminal"]
        guard let app = terminals.lazy.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first else {
            NSWorkspace.shared.open(folder)
            return
        }
        NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Context use with the statusline's context bands (amber at 55, red at 75).
private struct ContextBar: View {
    var percent: Double
    var tokens: Int?

    var body: some View {
        HStack(spacing: 6) {
            Text("ctx")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            MeterTrack(percent: percent, color: Threshold.contextLevel(percent).color)
            Text("\(Int(percent.rounded()))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Threshold.contextLevel(percent).color)
                .contentTransition(.numericText())
            if let tokens {
                Text(Money.tokens(tokens))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// A quota window as a ring, the way the statusline shows 5h and 7d.
private struct QuotaRing: View {
    var title: String
    var percent: Double?
    var caption: String?

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.18), lineWidth: 5)
                if let percent {
                    Circle()
                        .trim(from: 0, to: CGFloat(min(max(percent, 0), 100)) / 100)
                        .stroke(
                            Threshold.level(percent).color.gradient,
                            style: StrokeStyle(lineWidth: 5, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .shadow(color: Threshold.level(percent).color.opacity(0.45), radius: 3)
                }
                VStack(spacing: -1) {
                    Text(percent.map { "\(Int($0.rounded()))" } ?? "—")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(title)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 54, height: 54)
            Text(caption ?? " ")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .animation(.snappy, value: percent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(percent.map { "\(Int($0.rounded())) por cento" } ?? "sem leitura")")
    }
}

private struct UsageMeter: View {
    var title: String
    var percent: Double?
    var trailing: String?
    var live: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if live {
                    Circle()
                        .fill(Threshold.Level.green.color)
                        .frame(width: 6, height: 6)
                }
                Text(title)
                    .lineLimit(1)
                Spacer()
                if let percent {
                    Text("\(Int(percent.rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(Threshold.level(percent).color)
                        .contentTransition(.numericText())
                } else {
                    Text("—")
                        .foregroundStyle(.tertiary)
                }
                if let trailing {
                    Text(trailing)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .font(.callout)
            MeterTrack(percent: percent, color: percent.map { Threshold.level($0).color } ?? .clear)
        }
    }
}

private struct MeterTrack: View {
    var percent: Double?
    var color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                if let percent {
                    Capsule()
                        .fill(color.gradient)
                        .frame(width: geo.size.width * CGFloat(min(max(percent, 0), 100)) / 100)
                }
            }
        }
        .frame(height: 5)
        .animation(.snappy, value: percent)
    }
}

private struct SectionLabel: View {
    var text: String

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0.6)
    }
}

private extension View {
    /// Liquid Glass card. The id lets the glass flow between shapes when the
    /// Claude/Grok tab changes the card's contents.
    /// Radius and padding follow the Control Center modules.
    @ViewBuilder
    func glassCard(
        id: String,
        in namespace: Namespace.ID,
        padding: CGFloat = 14,
        radius: CGFloat = 24,
        interactive: Bool = false
    ) -> some View {
        if #available(macOS 26, *) {
            self
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(
                    interactive ? .regular.interactive() : .regular,
                    in: RoundedRectangle(cornerRadius: radius, style: .continuous)
                )
                .glassEffectID(id, in: namespace)
        } else {
            self
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }

    @ViewBuilder
    func glassCircle(id: String, in namespace: Namespace.ID) -> some View {
        if #available(macOS 26, *) {
            self
                .glassEffect(.regular.interactive(), in: Circle())
                .glassEffectID(id, in: namespace)
        } else {
            self.background(.regularMaterial, in: Circle())
        }
    }
}

/// MenuBarExtra paints an opaque material behind the SwiftUI view. Liquid Glass
/// only refracts what is actually behind the window, so that material has to go.
private struct ClearPopoverWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowClearView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? WindowClearView)?.punch()
    }
}

private final class WindowClearView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        punch()
    }

    override func layout() {
        super.layout()
        punch()
    }

    func punch() {
        guard let window, let content = window.contentView else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.clear.cgColor
        for subview in content.subviews where subview is NSVisualEffectView {
            subview.isHidden = true
        }
    }
}
