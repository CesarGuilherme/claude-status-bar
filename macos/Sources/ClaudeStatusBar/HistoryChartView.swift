import Charts
import SwiftUI

/// The `/stats` screen of Claude Code, in the panel: Overview (heatmap and
/// numbers) and Modelos (tokens per day by model and each model's share).
struct HistorySection: View {
    var input: HistoryInput
    @State private var range: HistoryRange = .all
    @State private var kind: HistoryKind
    @State private var hovered: Date?

    init(input: HistoryInput, kind: HistoryKind = .overview) {
        self.input = input
        _kind = State(initialValue: kind)
    }

    private var snapshot: HistorySnapshot {
        HistoryLog.snapshot(input: input, range: range, now: Date())
    }

    var body: some View {
        let snapshot = snapshot
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(HistoryKind.allCases) { item in
                    Button { withAnimation(.snappy) { kind = item } } label: {
                        Text(item.title)
                            .font(.callout.weight(kind == item ? .bold : .regular))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .foregroundStyle(kind == item ? Color.black : Color.primary)
                            .background {
                                if kind == item {
                                    Capsule().fill(StatsPalette.accent)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }

            HStack(spacing: 6) {
                ForEach(HistoryRange.allCases) { item in
                    if item != HistoryRange.allCases.first {
                        Text("·").foregroundStyle(.tertiary)
                    }
                    Button { withAnimation(.snappy) { range = item } } label: {
                        Text(item.title)
                            .fontWeight(range == item ? .bold : .regular)
                            .foregroundStyle(range == item ? StatsPalette.accent : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.caption)

            if snapshot.totalTokens == 0 && snapshot.sessions == 0 {
                Text(L10n.tr("No history in this period."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
            } else if kind == .overview {
                overview(snapshot)
                    .transition(.opacity)
            } else {
                models(snapshot)
                    .transition(.opacity)
            }
        }
    }

    // MARK: Overview

    private func overview(_ snapshot: HistorySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            heatmap(snapshot)
            HStack(spacing: 4) {
                Text(L10n.tr("Less"))
                ForEach(1..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(StatsPalette.heat(level))
                        .frame(width: 10, height: 10)
                }
                Text(L10n.tr("More"))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                GridRow {
                    stat(L10n.tr("Favorite model"), ModelMatch.displayName(snapshot.favoriteModel), bold: true)
                    stat(L10n.tr("Total tokens"), Money.tokens(snapshot.totalTokens))
                }
                GridRow {
                    stat(L10n.tr("Sessions"), "\(snapshot.sessions)")
                    stat(L10n.tr("Longest session"), HistoryLog.duration(snapshot.longestSession))
                }
                GridRow {
                    stat(L10n.tr("Active days"), "\(snapshot.activeDays)/\(snapshot.spanDays)")
                    stat(L10n.tr("Longest streak"), L10n.tr("%d days", snapshot.longestStreak), bold: true)
                }
                GridRow {
                    stat(L10n.tr("Most active day"), snapshot.busiestDay.map(dayText) ?? "—")
                    stat(L10n.tr("Current streak"), L10n.tr("%d days", snapshot.currentStreak), bold: true)
                }
            }

            if snapshot.splitKnown {
                Text(L10n.tr("Input %1$@ · Output %2$@ · Cache %3$@ read · %4$@ write", Money.tokens(snapshot.input), Money.tokens(snapshot.output), Money.tokens(snapshot.cacheRead), Money.tokens(snapshot.cacheWrite)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if let fun = StatsFun.line(input: snapshot.input, output: snapshot.output) {
                    Text(fun)
                        .font(.caption)
                        .foregroundStyle(StatsPalette.fun)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func heatmap(_ snapshot: HistorySnapshot) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 3) {
                    VStack(spacing: 3) {
                        Color.clear.frame(width: 22, height: 12)
                        ForEach(0..<7, id: \.self) { row in
                            // Rows run Monday to Sunday; label Mon, Wed and Fri in the system language.
                            Text(row % 2 == 0 && row < 6 ? Calendar.current.shortStandaloneWeekdaySymbols[row + 1] : "")
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                                .frame(width: 22, height: 10, alignment: .trailing)
                        }
                    }
                    ForEach(snapshot.weeks) { week in
                        VStack(spacing: 3) {
                            Text(week.monthLabel ?? " ")
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                                .fixedSize()
                                .frame(width: 10, height: 12, alignment: .leading)
                            ForEach(week.days) { cell in
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(cell.included ? StatsPalette.heat(HistoryLog.level(tokens: cell.heat, peak: snapshot.peak)) : Color.clear)
                                    .frame(width: 10, height: 10)
                                    .help(cell.included ? "\(dayText(cell.day)): \(Money.tokens(cell.tokens)) tokens" : "")
                            }
                        }
                        .id(week.id)
                    }
                }
            }
            .onAppear { proxy.scrollTo(snapshot.weeks.last?.id, anchor: .trailing) }
            .onChange(of: range) { proxy.scrollTo(snapshot.weeks.last?.id, anchor: .trailing) }
        }
    }

    private func stat(_ title: String, _ value: String, bold: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(bold ? .bold : .medium))
                .monospacedDigit()
                .foregroundStyle(StatsPalette.accent)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Modelos

    private func models(_ snapshot: HistorySnapshot) -> some View {
        let names = snapshot.models.map(ModelMatch.displayName)
        let picked = hovered.map { Calendar.current.startOfDay(for: $0) }
        let pickedPoints = snapshot.series.filter { $0.day == picked && $0.tokens > 0 }
        return VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("Tokens per day"))
                .font(.caption.weight(.semibold))
            Chart {
                ForEach(snapshot.series) { point in
                    LineMark(
                        x: .value("Dia", point.day, unit: .day),
                        y: .value("Tokens", point.tokens)
                    )
                    .foregroundStyle(by: .value("Modelo", ModelMatch.displayName(point.model)))
                    .interpolationMethod(.stepCenter)
                    .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                }
                if let picked {
                    RuleMark(x: .value("Dia", picked, unit: .day))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                        .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            tooltip(day: picked, points: pickedPoints)
                        }
                }
            }
            .chartForegroundStyleScale(domain: names, range: StatsPalette.series)
            .chartLegend(.hidden)
            .chartXSelection(value: $hovered)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel {
                        if let tokens = value.as(Double.self) {
                            Text(Money.tokens(Int(tokens))).font(.system(size: 8))
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated)).font(.system(size: 8))
                }
            }
            .frame(height: 150)

            HStack(spacing: 8) {
                ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                    HStack(spacing: 4) {
                        Circle().fill(StatsPalette.series[index % StatsPalette.series.count]).frame(width: 6, height: 6)
                        Text(name)
                    }
                }
            }
            .font(.caption2)

            LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)], spacing: 8) {
                ForEach(Array(snapshot.shares.enumerated()), id: \.element.id) { index, share in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Circle().fill(StatsPalette.series[index % StatsPalette.series.count]).frame(width: 6, height: 6)
                            Text(ModelMatch.displayName(share.model))
                                .font(.callout.weight(.semibold))
                                .lineLimit(1)
                            Text(String(format: "%.1f%%", share.percent))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        if share.splitKnown {
                            Text(L10n.tr("Input %1$@ · Output %2$@", Money.tokens(share.input), Money.tokens(share.output)))
                            Text(L10n.tr("Cache %1$@ read · %2$@ write", Money.tokens(share.cacheRead), Money.tokens(share.cacheWrite)))
                        } else {
                            Text(L10n.tr("%@ tokens", Money.tokens(share.tokens)))
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func tooltip(day: Date, points: [HistoryPoint]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(dayText(day)).font(.caption2.weight(.semibold))
            if points.isEmpty {
                Text(L10n.tr("no usage")).font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(points) { point in
                Text("\(ModelMatch.displayName(point.model)): \(Money.tokens(point.tokens))")
                    .font(.caption2)
                    .monospacedDigit()
            }
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func dayText(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated))
    }
}

enum HistoryKind: String, CaseIterable, Identifiable {
    case overview, models
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: L10n.tr("Overview")
        case .models: L10n.tr("Models")
        }
    }
}

/// Colors of the `/stats` screen: orange accent, rust heatmap, blue fun line.
enum StatsPalette {
    static let accent = Color(red: 0.96, green: 0.62, blue: 0.30)
    static let fun = Color(red: 0.55, green: 0.72, blue: 0.98)
    static let series: [Color] = [
        Color(red: 0.62, green: 0.78, blue: 0.98),
        Color(red: 0.30, green: 0.52, blue: 0.95),
        Color(red: 0.98, green: 0.80, blue: 0.28),
        Color(red: 0.92, green: 0.48, blue: 0.32),
    ]

    static func heat(_ level: Int) -> Color {
        switch level {
        case 1: Color(red: 0.36, green: 0.22, blue: 0.20)
        case 2: Color(red: 0.52, green: 0.30, blue: 0.24)
        case 3: Color(red: 0.72, green: 0.40, blue: 0.29)
        case 4: Color(red: 0.86, green: 0.50, blue: 0.36)
        default: Color.primary.opacity(0.08)
        }
    }
}

/// The `/stats` comparison line, with a well-known book in each language.
enum StatsFun {
    /// Rough token counts. A Christmas Carol matches the ratio `/stats` uses.
    static let books: [String: (title: String, tokens: Int)] = [
        "en": ("A Christmas Carol", 37_000),
        "pt": ("Dom Casmurro", 90_000),
        "es": ("Pedro Páramo", 45_000),
        "fr": ("Le Petit Prince", 25_000),
        "de": ("Die Verwandlung", 30_000),
    ]

    static func line(input: Int, output: Int, language: String = L10n.language) -> String? {
        let code = String(language.prefix(2))
        let book = books[code] ?? books["en"]!
        let times = (input + output) / book.tokens
        guard times >= 1 else { return nil }
        return L10n.tr("Your input and output add up to ~%1$d× the tokens in %2$@", times, book.title)
    }
}
