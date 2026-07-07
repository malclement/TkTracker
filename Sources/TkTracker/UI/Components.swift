import SwiftUI

struct StatTile: View {
    let label: String
    let value: String
    var sub: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .contentTransition(.numericText())
            if let sub {
                Text(sub)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// Horizontal share-of-total bar used in table rows.
struct ShareBar: View {
    let fraction: Double
    var color: Color = Theme.accent

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary.opacity(0.6))
                Capsule()
                    .fill(color.opacity(0.85))
                    .frame(width: max(2, geo.size.width * fraction))
            }
        }
        .frame(height: 5)
    }
}

/// Context-window fill for a session; color escalates as compaction nears.
struct ContextGauge: View {
    let fraction: Double

    var body: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary.opacity(0.6))
                Capsule()
                    .fill(Theme.contextColor(fraction))
                    .frame(width: max(2, 36 * fraction))
            }
            .frame(width: 36, height: 4)
            Text(Format.percent(fraction))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

struct Swatch: View {
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(color)
            .frame(width: 9, height: 9)
    }
}

struct LiveDot: View {
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(Theme.good)
            .frame(width: 7, height: 7)
            .opacity(pulsing ? 0.35 : 1)
            .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}

/// 24-hour activity sparkline for the popover; single series, no chrome.
struct HourSparkline: View {
    let points: [HourPoint]
    var currentHour: Date

    var body: some View {
        let peak = max(points.map(\.cost).max() ?? 0, 0.0001)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(points) { p in
                let h = max(2, 40 * p.cost / peak)
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(p.date == currentHour ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
                    .frame(height: h)
                    .frame(maxWidth: .infinity, alignment: .bottom)
            }
        }
        .frame(height: 42, alignment: .bottom)
        .accessibilityLabel("Hourly spend, last 24 hours")
    }
}

/// Time progress through the current 5-hour billing block.
struct BlockGauge: View {
    let block: BlockInfo
    let now: Date

    var body: some View {
        let elapsed = min(1, max(0, now.timeIntervalSince(block.start) / StatsBuilder.blockLength))
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Current 5h block")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Format.money(block.cost))
                    .font(.caption.weight(.semibold).monospacedDigit())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary.opacity(0.6))
                    Capsule()
                        .fill(Theme.accent.opacity(0.85))
                        .frame(width: max(3, geo.size.width * elapsed))
                }
            }
            .frame(height: 5)
            HStack {
                Text("\(Format.tokens(block.totals.total)) tokens · \(block.totals.messages) msgs")
                Spacer()
                Text(block.isActive
                     ? "\(Format.duration(block.end.timeIntervalSince(now))) left"
                     : "ended")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }
}

struct EmptyDataView: View {
    let scanning: Bool
    let root: String

    var body: some View {
        VStack(spacing: 8) {
            if scanning {
                ProgressView()
                Text("Scanning sessions…")
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "tray")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                Text("No Claude Code sessions found")
                    .foregroundStyle(.secondary)
                Text(root)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
