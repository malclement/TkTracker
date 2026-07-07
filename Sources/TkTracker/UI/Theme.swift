import SwiftUI
import AppKit

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension Color {
    /// Appearance-adaptive color; the palette is validated per mode, not auto-flipped.
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(hex: dark)
                : NSColor(hex: light)
        })
    }
}

/// Chart palette. Slot order Fable → Sonnet → Opus → Haiku is load-bearing:
/// it was chosen so adjacent stacked segments stay CVD-distinguishable in both
/// modes (validated: light worst adjacent ΔE 16.6, dark 15.7).
extension ModelFamily {
    // Stored once: dynamic NSColors compare by instance, and per-render allocation
    // would break both Color equality and the chart's foreground scale.
    private static let anchors: [ModelFamily: Color] = [
        .fable: .adaptive(light: 0x4A3AA7, dark: 0x9085E9),
        .sonnet: .adaptive(light: 0x1BAF7A, dark: 0x199E70),
        .opus: .adaptive(light: 0x2A78D6, dark: 0x3987E5),
        .haiku: .adaptive(light: 0xEDA100, dark: 0xC98500),
        .other: .adaptive(light: 0x898781, dark: 0x898781),
    ]

    var color: Color { Self.anchors[self] ?? Color.gray }
}

/// Per-model colors: hue = family, lightness = generation. The newest version of
/// a family takes the strongest step; older ones recede toward the surface. Every
/// ramp passed the ordinal palette validator (monotone lightness, ΔL ≥ 0.06 gaps,
/// ≥2:1 light-end contrast, single hue) in both modes, and family boundary pairs
/// in the stack keep CVD ΔE ≥ 49.
struct ModelColorScale {
    /// Steps per family, strongest (newest) first — light/dark validated separately.
    /// Stored constants so identical colors compare equal and scales stay stable.
    private static let ramps: [ModelFamily: [Color]] = [
        .fable: [
            .adaptive(light: 0x4A3AA7, dark: 0x9085E9),
            .adaptive(light: 0x6E61C8, dark: 0x7466C2),
            .adaptive(light: 0x9188DB, dark: 0x584D9B),
            .adaptive(light: 0xADA5E8, dark: 0x584D9B),
        ],
        .sonnet: [
            .adaptive(light: 0x128057, dark: 0x199E70),
            .adaptive(light: 0x1BAF7A, dark: 0x15825C),
            .adaptive(light: 0x4FC697, dark: 0x106847),
        ],
        .opus: [
            .adaptive(light: 0x1C5CAB, dark: 0x57A0F2),
            .adaptive(light: 0x2A78D6, dark: 0x3987E5),
            .adaptive(light: 0x5598E7, dark: 0x2568B6),
            .adaptive(light: 0x86B6EF, dark: 0x184F95),
        ],
        // Yellow can't go lighter and stay legible; older steps darken instead.
        .haiku: [
            .adaptive(light: 0xEDA100, dark: 0xC98500),
            .adaptive(light: 0xBE7E00, dark: 0xA76E00),
            .adaptive(light: 0x8F5D00, dark: 0x865800),
        ],
        .other: [
            .adaptive(light: 0x898781, dark: 0x898781),
            .adaptive(light: 0xA5A39C, dark: 0x6E6C66),
        ],
    ]

    static func ramp(for family: ModelFamily) -> [Color] {
        Self.ramps[family] ?? [ModelFamily.other.color]
    }

    private let colors: [String: Color]
    /// Short names in stack order (family, then version ascending).
    let orderedNames: [String]

    init(palette: [ModelPaletteEntry]) {
        var assigned: [String: Color] = [:]
        for (_, entries) in Dictionary(grouping: palette, by: \.family) {
            guard let family = entries.first?.family else { continue }
            let ramp = Self.ramp(for: family)
            // Newest version claims the strongest step; overflow shares the last one.
            for (index, entry) in entries.sorted(by: { $0.version > $1.version }).enumerated() {
                assigned[entry.name] = ramp[min(index, ramp.count - 1)]
            }
        }
        colors = assigned
        orderedNames = palette.map(\.name)
    }

    func color(for name: String, family: ModelFamily = .other) -> Color {
        colors[name] ?? family.color
    }
}

enum Theme {
    /// App accent — the Fable violet.
    static let accent = Color.adaptive(light: 0x4A3AA7, dark: 0x9085E9)

    // Status ramp (reserved for state, never used as a series color).
    static let good = Color.adaptive(light: 0x0CA30C, dark: 0x0CA30C)
    static let warning = Color.adaptive(light: 0xFAB219, dark: 0xFAB219)
    static let serious = Color.adaptive(light: 0xEC835A, dark: 0xEC835A)
    static let critical = Color.adaptive(light: 0xD03B3B, dark: 0xD03B3B)

    static func contextColor(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.6: return .secondary
        case ..<0.8: return warning
        case ..<0.92: return serious
        default: return critical
        }
    }
}

struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.quaternary.opacity(0.35))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.separator.opacity(0.5), lineWidth: 1)
            )
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}
