import SwiftUI

/// Tracked-caps section label; the one place labels get uppercased.
struct Eyebrow: View {
    let text: String
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
            }
            Text(text.uppercased())
                .font(.caption2.weight(.semibold))
                .kerning(0.7)
                .foregroundStyle(.secondary)
        }
    }
}

/// Tinted capsule badge for compact state (deltas, burn rate, live count).
struct Chip: View {
    let text: String
    var tint: Color = Theme.accent
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 3.5) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 8.5, weight: .bold))
            }
            Text(text)
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6.5)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(tint.opacity(0.14)))
        .lineLimit(1)
        .fixedSize()
    }
}

struct StatTile: View {
    let label: String
    let value: String
    var icon: String? = nil
    var sub: String? = nil
    /// Signed fraction rendered as a tinted delta chip; up = spending more.
    var delta: Double? = nil
    var deltaLabel: String = "vs yesterday"

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Eyebrow(text: label, icon: icon)
            Text(value)
                .font(Theme.metric(24))
                .contentTransition(.numericText())
            Group {
                if let delta {
                    HStack(spacing: 5) {
                        Chip(
                            text: Format.signedPercent(delta),
                            tint: delta >= 0 ? Theme.serious : Theme.good,
                            icon: delta >= 0 ? "arrow.up.right" : "arrow.down.right"
                        )
                        Text(deltaLabel)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                } else if let sub {
                    Text(sub)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(height: 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 14)
    }
}

/// Horizontal share-of-total bar used in table rows.
struct ShareBar: View {
    let fraction: Double
    var color: Color = Theme.accent

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule()
                    .fill(Theme.gaugeFill(color))
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
                Capsule().fill(Theme.track)
                Capsule()
                    .fill(Theme.gaugeFill(Theme.contextColor(fraction)))
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(Theme.good)
            .frame(width: 7, height: 7)
            .shadow(color: Theme.good.opacity(0.55), radius: pulsing ? 3.5 : 1.5)
            .opacity(pulsing ? 0.45 : 1)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                value: pulsing
            )
            .onAppear { pulsing = !reduceMotion }
    }
}

/// 24-hour activity meter for the popover: violet haze for past hours,
/// full accent for the hour underway, recessed stubs where nothing ran.
struct HourSparkline: View {
    let points: [HourPoint]
    var currentHour: Date

    var body: some View {
        let peak = max(points.map(\.cost).max() ?? 0, 0.0001)
        VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(points) { p in
                    let h = max(3, 40 * p.cost / peak)
                    bar(for: p)
                        .frame(height: h)
                        .frame(maxWidth: .infinity, alignment: .bottom)
                }
            }
            .frame(height: 42, alignment: .bottom)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Theme.track)
                    .frame(height: 1)
                    .offset(y: 2)
            }
            HStack {
                Text("24h ago")
                Spacer()
                Text("now")
            }
            .font(.caption2)
            .foregroundStyle(.quaternary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hourly spend, last 24 hours")
    }

    @ViewBuilder
    private func bar(for p: HourPoint) -> some View {
        let shape = RoundedRectangle(cornerRadius: 1.5, style: .continuous)
        if p.date == currentHour {
            shape.fill(Theme.gaugeFill(Theme.accent))
        } else if p.cost > 0 {
            shape.fill(Theme.accent.opacity(0.30))
        } else {
            shape.fill(Theme.track)
        }
    }
}

/// Time progress through the current 5-hour billing block,
/// drawn as five segments — one per hour.
struct BlockGauge: View {
    let block: BlockInfo
    let now: Date

    var body: some View {
        let elapsed = min(1, max(0, now.timeIntervalSince(block.start) / StatsBuilder.blockLength))
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Eyebrow(text: "Current 5h block", icon: "clock")
                Spacer()
                Text(Format.money(block.cost))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .contentTransition(.numericText(value: block.cost))
            }
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { hour in
                    let fill = min(1, max(0, elapsed * 5 - Double(hour)))
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.track)
                            if fill > 0 {
                                Capsule()
                                    .fill(Theme.gaugeFill(Theme.accent))
                                    .frame(width: max(3, geo.size.width * fill))
                            }
                        }
                    }
                    .frame(height: 6)
                }
            }
            .help("Each segment is one hour of the block")
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
    /// Tracked source roots, e.g. ("Claude Code", "~/.claude/projects").
    let roots: [(name: String, path: String)]

    var body: some View {
        VStack(spacing: 9) {
            if scanning {
                ProgressView()
                Text("Scanning sessions…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "tray")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Theme.track))
                Text(roots.count == 1
                     ? "No \(roots[0].name) sessions found"
                     : "No sessions found")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(roots, id: \.path) { root in
                        Text(roots.count == 1 ? root.path : "\(root.name)  \(root.path)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
