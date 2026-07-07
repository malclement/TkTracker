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
    var color: Color {
        switch self {
        case .fable: return .adaptive(light: 0x4A3AA7, dark: 0x9085E9)
        case .sonnet: return .adaptive(light: 0x1BAF7A, dark: 0x199E70)
        case .opus: return .adaptive(light: 0x2A78D6, dark: 0x3987E5)
        case .haiku: return .adaptive(light: 0xEDA100, dark: 0xC98500)
        case .other: return .adaptive(light: 0x898781, dark: 0x898781)
        }
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
