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
                Text("Sem histórico neste período.")
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
                Text("Menos")
                ForEach(1..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(StatsPalette.heat(level))
                        .frame(width: 10, height: 10)
                }
                Text("Mais")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                GridRow {
                    stat("Modelo favorito", ModelMatch.displayName(snapshot.favoriteModel), bold: true)
                    stat("Total de tokens", Money.tokens(snapshot.totalTokens))
                }
                GridRow {
                    stat("Sessões", "\(snapshot.sessions)")
                    stat("Sessão mais longa", HistoryLog.duration(snapshot.longestSession))
                }
                GridRow {
                    stat("Dias ativos", "\(snapshot.activeDays)/\(snapshot.spanDays)")
                    stat("Maior sequência", "\(snapshot.longestStreak) dias", bold: true)
                }
                GridRow {
                    stat("Dia mais ativo", snapshot.busiestDay.map(dayText) ?? "—")
                    stat("Sequência atual", "\(snapshot.currentStreak) dias", bold: true)
                }
            }

            if snapshot.splitKnown {
                Text("Entrada \(Money.tokens(snapshot.input)) · Saída \(Money.tokens(snapshot.output)) · Cache \(Money.tokens(snapshot.cacheRead)) leitura · \(Money.tokens(snapshot.cacheWrite)) escrita")
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
                            Text(row == 0 ? "seg" : row == 2 ? "qua" : row == 4 ? "sex" : "")
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
            Text("Tokens por dia")
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
                            Text("Entrada \(Money.tokens(share.input)) · Saída \(Money.tokens(share.output))")
                            Text("Cache \(Money.tokens(share.cacheRead)) leit. · \(Money.tokens(share.cacheWrite)) escr.")
                        } else {
                            Text("\(Money.tokens(share.tokens)) tokens")
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
                Text("sem uso").font(.caption2).foregroundStyle(.secondary)
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
        date.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "pt_BR")))
    }
}

enum HistoryKind: String, CaseIterable, Identifiable {
    case overview, models
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: "Visão geral"
        case .models: "Modelos"
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

/// The `/stats` comparison line, with a Brazilian book.
enum StatsFun {
    /// Dom Casmurro, about 67k words, is roughly 90k tokens.
    static let bookTokens = 90_000
    static let book = "Dom Casmurro"

    static func line(input: Int, output: Int) -> String? {
        let times = (input + output) / bookTokens
        guard times >= 1 else { return nil }
        return "Sua entrada e saída somam ~\(times)× os tokens de \(book)"
    }
}
