import Foundation

/// USD per million tokens for one model tier.
struct ModelPricing: Sendable, Equatable {
    let input: Double
    let output: Double
    let cacheRead: Double
    let cacheWrite5m: Double
    let cacheWrite1h: Double

    init(input: Double, output: Double) {
        self.input = input
        self.output = output
        // Standard Anthropic multipliers: read 0.1x, 5m write 1.25x, 1h write 2x.
        self.cacheRead = input * 0.1
        self.cacheWrite5m = input * 1.25
        self.cacheWrite1h = input * 2.0
    }
}

enum Pricing {
    /// Web search billed per request, on top of tokens.
    static let webSearchPer1000: Double = 10.0

    /// Substring-matched so bare ids, dated ids and bedrock/vertex-style ids all resolve.
    /// Order matters: most specific first.
    static func pricing(for model: String) -> ModelPricing? {
        let m = model.lowercased()
        if m.isEmpty || m.contains("synthetic") { return nil }
        if m.contains("fable") || m.contains("mythos") { return ModelPricing(input: 10, output: 50) }
        if m.contains("opus-4-5") || m.contains("opus-4-6") || m.contains("opus-4-7") || m.contains("opus-4-8") {
            return ModelPricing(input: 5, output: 25)
        }
        if m.contains("opus") { return ModelPricing(input: 15, output: 75) } // opus 4.1 and older
        // Sonnet 5 sticker price; intro pricing ($2/$10 through 2026-08-31) makes this a slight overestimate.
        if m.contains("sonnet") { return ModelPricing(input: 3, output: 15) }
        if m.contains("haiku-4") { return ModelPricing(input: 1, output: 5) }
        if m.contains("3-5-haiku") || m.contains("haiku-3-5") { return ModelPricing(input: 0.8, output: 4) }
        if m.contains("haiku") { return ModelPricing(input: 0.25, output: 1.25) }
        if m == "claude-2" || m.contains("claude-2.") { return ModelPricing(input: 8, output: 24) }
        if m.contains("instant") { return ModelPricing(input: 0.8, output: 2.4) }
        return nil
    }

    static func cost(model: String, totals: TokenTotals) -> Double {
        guard let p = pricing(for: model) else { return 0 }
        let mtok = 1_000_000.0
        var usd = Double(totals.input) / mtok * p.input
        usd += Double(totals.output) / mtok * p.output
        usd += Double(totals.cacheRead) / mtok * p.cacheRead
        usd += Double(totals.cacheWrite5m) / mtok * p.cacheWrite5m
        usd += Double(totals.cacheWrite1h) / mtok * p.cacheWrite1h
        usd += Double(totals.webSearches) / 1000.0 * webSearchPer1000
        return usd
    }

    /// What the same input volume would have cost with no prompt cache, minus what it actually cost.
    /// Positive means the cache saved money.
    static func cacheSavings(model: String, totals: TokenTotals) -> Double {
        guard let p = pricing(for: model) else { return 0 }
        let mtok = 1_000_000.0
        let promptTokens = Double(totals.input + totals.cacheRead + totals.cacheWrite5m + totals.cacheWrite1h)
        let uncached = promptTokens / mtok * p.input
        let actual = Double(totals.input) / mtok * p.input
            + Double(totals.cacheRead) / mtok * p.cacheRead
            + Double(totals.cacheWrite5m) / mtok * p.cacheWrite5m
            + Double(totals.cacheWrite1h) / mtok * p.cacheWrite1h
        return uncached - actual
    }

    /// Context window used for the session context gauge. Claude Code appends
    /// "[1m]" to the model id when the 1M-token window is active; everything
    /// else runs the standard 200K window.
    static func contextWindow(for model: String) -> Int64 {
        model.lowercased().contains("[1m]") ? 1_000_000 : 200_000
    }
}

/// Model family, used for stable chart colors and grouping.
enum ModelFamily: String, CaseIterable, Codable, Sendable {
    case fable = "Fable"
    case sonnet = "Sonnet"
    case opus = "Opus"
    case haiku = "Haiku"
    case other = "Other"

    init(model: String) {
        let m = model.lowercased()
        if m.contains("fable") || m.contains("mythos") { self = .fable }
        else if m.contains("opus") { self = .opus }
        else if m.contains("sonnet") { self = .sonnet }
        else if m.contains("haiku") { self = .haiku }
        else { self = .other }
    }

    /// Fixed stacking/legend order — validated for CVD-safe adjacency in both color modes.
    static let displayOrder: [ModelFamily] = [.fable, .sonnet, .opus, .haiku, .other]

    /// Short display name for a full model id, e.g. "claude-opus-4-8" -> "Opus 4.8".
    static func shortName(for model: String) -> String {
        let family = ModelFamily(model: model)
        guard family != .other else { return model }
        let version = versionDigits(model).prefix(2).joined(separator: ".")
        return version.isEmpty ? family.rawValue : "\(family.rawValue) \(version)"
    }

    /// Numeric generation for ordering within a family: "claude-opus-4-8" -> 4.8.
    static func version(of model: String) -> Double {
        Double(versionDigits(model).prefix(2).joined(separator: ".")) ?? 0
    }

    /// Version fragments like "4-8" or "5" from a model id (date suffixes excluded).
    private static func versionDigits(_ model: String) -> [String] {
        model.lowercased().split(separator: "-").compactMap { part -> String? in
            guard part.count <= 2, part.allSatisfy(\.isNumber) else { return nil }
            return String(part)
        }
    }
}
