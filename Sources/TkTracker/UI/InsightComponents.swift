import SwiftUI

/// Consumption bar for a plan allowance (5-hour block, rolling week).
///
/// Escalates through the status ramp as the allowance fills, and never carries
/// meaning by color alone — the percentage and the remaining amount are always
/// spelled out beside it.
struct AllowanceGauge: View {
    let title: String
    let gauge: PlanGauge
    /// Shown when the allowance is on track to run out inside the window.
    var exhaustsAt: Date?
    var footnote: String?

    /// Shares the app-wide escalation thresholds; only the calm end differs from
    /// a context gauge.
    private var tint: Color {
        Theme.fillColor(gauge.fraction, calm: Theme.accent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow(text: title)
                Spacer()
                Text(Format.percent(gauge.fraction))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(tint)
            }

            ShareBar(fraction: gauge.fraction, color: tint, height: 6)

            HStack(spacing: 6) {
                Text("\(Format.money(gauge.used)) of \(Format.money(gauge.limit))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let exhaustsAt {
                    Chip(
                        text: "runs out \(exhaustsAt.formatted(date: .omitted, time: .shortened))",
                        tint: Theme.serious,
                        icon: "hourglass"
                    )
                }
                Spacer(minLength: 0)
            }

            if let footnote {
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(
            "\(Format.percent(gauge.fraction)) used, \(Format.money(gauge.remaining)) remaining of \(Format.money(gauge.limit))"
        )
    }
}

/// Weekday × hour-of-day activity grid.
///
/// Sequential single-hue ramp built from the app accent — deliberately *not* the
/// categorical model palette, which encodes model identity and must never be
/// reused to encode magnitude. Intensity is on a square-root scale so ordinary
/// hours stay visible next to an outlier afternoon.
struct ActivityHeatmap: View {
    var calendar: Calendar = .current

    /// Derived once at init, not as computed properties.
    ///
    /// Both of these are read from inside the nested 7×24 `ForEach`, so as
    /// computed properties they rebuilt the whole dictionary and re-scanned every
    /// cost for each of the 168 cells — quadratic work on the main thread, on
    /// every stats change and every scroll or hover pass.
    private let byKey: [Int: HeatCell]
    private let peak: Double

    init(cells: [HeatCell], calendar: Calendar = .current) {
        self.calendar = calendar
        self.byKey = Dictionary(cells.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.peak = max(cells.map(\.cost).max() ?? 0, 0.0001)
        self.busiest = cells.max(by: { $0.cost < $1.cost })
    }

    private let busiest: HeatCell?

    /// Weekday numbers in the user's week order (Monday-first in most of Europe,
    /// Sunday-first in the US) rather than a hardcoded 1...7.
    private var weekdayOrder: [Int] {
        let first = calendar.firstWeekday
        return (0..<7).map { ((first - 1 + $0) % 7) + 1 }
    }

    private func symbol(_ weekday: Int) -> String {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return symbols.indices.contains(weekday - 1) ? symbols[weekday - 1] : "?"
    }

    private func intensity(_ cost: Double) -> Double {
        guard cost > 0 else { return 0 }
        return min(1, (cost / peak).squareRoot())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Eyebrow(text: "When you work", icon: "calendar")
                Spacer()
                legend
            }

            VStack(spacing: 2) {
                ForEach(weekdayOrder, id: \.self) { weekday in
                    HStack(spacing: 2) {
                        Text(symbol(weekday))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .frame(width: 18, alignment: .leading)
                        ForEach(0..<24, id: \.self) { hour in
                            let cell = byKey[weekday * 100 + hour]
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(
                                    cell.map { Theme.accent.opacity(0.12 + 0.88 * intensity($0.cost)) }
                                        ?? Theme.track
                                )
                                .frame(height: 13)
                                .frame(maxWidth: .infinity)
                                .help(tooltip(weekday: weekday, hour: hour, cell: cell))
                        }
                    }
                }
                HStack(spacing: 2) {
                    Spacer().frame(width: 18)
                    ForEach(0..<24, id: \.self) { hour in
                        Text(hour % 6 == 0 ? "\(hour)" : "")
                            .font(.system(size: 8))
                            .foregroundStyle(.quaternary)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Activity by weekday and hour")
        .accessibilityValue(busiestDescription)
    }

    private var legend: some View {
        HStack(spacing: 3) {
            Text("less").font(.system(size: 8)).foregroundStyle(.quaternary)
            ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { step in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(step == 0 ? Theme.track : Theme.accent.opacity(0.12 + 0.88 * step))
                    .frame(width: 8, height: 8)
            }
            Text("more").font(.system(size: 8)).foregroundStyle(.quaternary)
        }
    }

    private func tooltip(weekday: Int, hour: Int, cell: HeatCell?) -> String {
        let day = calendar.standaloneWeekdaySymbols.indices.contains(weekday - 1)
            ? calendar.standaloneWeekdaySymbols[weekday - 1]
            : ""
        let slot = "\(day) \(String(format: "%02d:00", hour))"
        guard let cell else { return "\(slot) — no activity" }
        return "\(slot) — \(Format.money(cell.cost)) · \(Format.tokens(cell.tokens)) tokens"
    }

    private var busiestDescription: String {
        guard let busiest else { return "no activity" }
        let day = calendar.standaloneWeekdaySymbols.indices.contains(busiest.weekday - 1)
            ? calendar.standaloneWeekdaySymbols[busiest.weekday - 1]
            : ""
        return "busiest \(day) at \(busiest.hour):00, \(Format.money(busiest.cost))"
    }
}

/// Banner shown when the last scan had a problem, or an update is available.
struct NoticeBanner: View {
    let text: String
    var icon: String = "exclamationmark.triangle.fill"
    var tint: Color = Theme.warning
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint.opacity(0.12))
        )
        .accessibilityElement(children: .combine)
    }
}
