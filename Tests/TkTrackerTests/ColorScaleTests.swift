import Testing
import SwiftUI
@testable import TkTracker

@Suite("Model color scale")
struct ColorScaleTests {
    private func entry(_ name: String, _ family: ModelFamily, _ version: Double) -> ModelPaletteEntry {
        ModelPaletteEntry(name: name, family: family, version: version)
    }

    @Test func newestVersionGetsStrongestStep() {
        let scale = ModelColorScale(palette: [
            entry("Opus 4.5", .opus, 4.5),
            entry("Opus 4.6", .opus, 4.6),
            entry("Opus 4.7", .opus, 4.7),
            entry("Opus 4.8", .opus, 4.8),
            entry("Fable 5", .fable, 5),
        ])
        let ramp = ModelColorScale.ramp(for: .opus)
        #expect(scale.color(for: "Opus 4.8") == ramp[0])
        #expect(scale.color(for: "Opus 4.7") == ramp[1])
        #expect(scale.color(for: "Opus 4.6") == ramp[2])
        #expect(scale.color(for: "Opus 4.5") == ramp[3])
        #expect(scale.color(for: "Fable 5") == ModelColorScale.ramp(for: .fable)[0])
    }

    @Test func overflowSharesLastStepAndUnknownFallsBackToFamily() {
        let scale = ModelColorScale(palette: [
            entry("Sonnet 5", .sonnet, 5),
            entry("Sonnet 4.6", .sonnet, 4.6),
            entry("Sonnet 4.5", .sonnet, 4.5),
            entry("Sonnet 4", .sonnet, 4),
            entry("Sonnet 3.7", .sonnet, 3.7),
        ])
        let ramp = ModelColorScale.ramp(for: .sonnet)
        // 5 versions on a 3-step ramp: the two oldest share the lightest step.
        #expect(scale.color(for: "Sonnet 4") == ramp[ramp.count - 1])
        #expect(scale.color(for: "Sonnet 3.7") == ramp[ramp.count - 1])
        // Unknown names fall back to the family anchor.
        #expect(scale.color(for: "Mystery", family: .haiku) == ModelFamily.haiku.color)
    }

    @Test func gptFamilyHasItsOwnRampAndNeverTouchesExisting() {
        // A mixed Claude + Codex palette: GPT models take the magenta ramp,
        // Anthropic families keep exactly the assignment they had without them.
        let anthropicOnly = ModelColorScale(palette: [
            entry("Fable 5", .fable, 5),
            entry("Opus 4.8", .opus, 4.8),
        ])
        let mixed = ModelColorScale(palette: [
            entry("Fable 5", .fable, 5),
            entry("Opus 4.8", .opus, 4.8),
            entry("Codex Mini 5.1", .gpt, 5.1),
            entry("Codex 5.3", .gpt, 5.3),
            entry("GPT-5.4", .gpt, 5.4),
            entry("GPT-5.5", .gpt, 5.5),
        ])
        let ramp = ModelColorScale.ramp(for: .gpt)
        #expect(ramp.count == 4)
        #expect(mixed.color(for: "GPT-5.5") == ramp[0]) // newest = strongest
        #expect(mixed.color(for: "GPT-5.4") == ramp[1])
        #expect(mixed.color(for: "Codex 5.3") == ramp[2])
        #expect(mixed.color(for: "Codex Mini 5.1") == ramp[3])
        #expect(mixed.color(for: "Fable 5") == anthropicOnly.color(for: "Fable 5"))
        #expect(mixed.color(for: "Opus 4.8") == anthropicOnly.color(for: "Opus 4.8"))
        // GPT sits between Haiku and Other in the validated stack order.
        #expect(ModelFamily.displayOrder == [.fable, .sonnet, .opus, .haiku, .gpt, .other])
    }

    @Test func versionTiesBreakDeterministically() {
        let a = ModelColorScale(palette: [
            entry("GPT-5.5", .gpt, 5.5),
            entry("Codex 5.5", .gpt, 5.5),
        ])
        let b = ModelColorScale(palette: [
            entry("Codex 5.5", .gpt, 5.5),
            entry("GPT-5.5", .gpt, 5.5),
        ])
        #expect(a.color(for: "GPT-5.5") == b.color(for: "GPT-5.5"))
        #expect(a.color(for: "Codex 5.5") == b.color(for: "Codex 5.5"))
        #expect(a.color(for: "GPT-5.5") != a.color(for: "Codex 5.5"))
    }
}
