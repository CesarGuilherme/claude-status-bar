import AppKit
import SwiftUI

struct MenuBarLabel: View {
    var model: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let working = model.sessions.contains { $0.isWorking(now: context.date) }
            HStack(spacing: 5) {
                ClaudeMark()
                    .frame(width: 14, height: 14)
                    .foregroundStyle(alertColor ?? Color.primary)
                    .overlay(alignment: .topTrailing) {
                        if working {
                            Circle()
                                .fill(Threshold.Level.green.color)
                                .frame(width: 5, height: 5)
                                .offset(x: 2, y: -1)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    MiniMeter(title: "5h", percent: model.usage?.fiveHour?.utilization)
                    MiniMeter(title: "7d", percent: model.usage?.sevenDay?.utilization)
                }
            }
            .animation(.snappy, value: working)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .help(helpText)
    }

    /// Amber or red once either window passes the statusline's warning band.
    private var alertColor: Color? {
        let worst = [model.usage?.fiveHour?.utilization, model.usage?.sevenDay?.utilization].compactMap { $0 }.max()
        guard let worst, Threshold.level(worst) != .green else { return nil }
        return Threshold.level(worst).color
    }

    private var helpText: String {
        let five = percent(model.usage?.fiveHour?.utilization)
        let seven = percent(model.usage?.sevenDay?.utilization)
        return L10n.tr("5h %1$@, 7d %2$@. %3$d live sessions", five, seven, model.sessions.count)
    }

    private var accessibilityText: String {
        let five = model.usage?.fiveHour?.utilization.map { L10n.tr("5 hours %d percent", Int($0.rounded())) } ?? L10n.tr("5 hours, no reading")
        let seven = model.usage?.sevenDay?.utilization.map { L10n.tr("7 days %d percent", Int($0.rounded())) } ?? L10n.tr("7 days, no reading")
        return L10n.tr("%1$@, %2$@, %3$d live sessions", five, seven, model.sessions.count)
    }

    private func percent(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded()))%" } ?? "—"
    }
}

/// The Claude mark (theSVG, CC0) as a template image, so it takes the menu
/// bar's color. It ships in the module's resources; the asterisk is only a
/// fallback if that file is missing.
struct ClaudeMark: View {
    private static let image: NSImage? = {
        guard let url = Bundle.module.url(forResource: "claude", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        return image
    }()

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "asterisk")
                .font(.system(size: 12, weight: .semibold))
        }
    }
}

/// The Tahoe menu bar is transparent, so the track is darker than before and
/// the fill carries a soft shadow to stay readable over any wallpaper.
private struct MiniMeter: View {
    var title: String
    var percent: Double?

    var body: some View {
        HStack(spacing: 3) {
            Text(title)
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .frame(width: 14, alignment: .trailing)
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.28))
                if let percent {
                    // One color per band, the terminal statusline's: green under
                    // 70%, yellow under 90%, red from 90% up to 100%.
                    Capsule()
                        .fill(Threshold.level(percent).color.gradient)
                        .frame(width: max(3.5, 26 * CGFloat(min(max(percent, 0), 100)) / 100))
                        .shadow(color: Threshold.level(percent).color.opacity(0.6), radius: 1.5)
                }
            }
            .frame(width: 26, height: 3.5)
            .animation(.snappy, value: percent)
        }
    }
}

extension Threshold.Level {
    var color: Color {
        switch self {
        case .green: Color(red: 0.36, green: 0.72, blue: 0.42)
        case .yellow: Color(red: 0.96, green: 0.80, blue: 0.20)
        case .red: Color(red: 0.86, green: 0.32, blue: 0.34)
        }
    }
}
