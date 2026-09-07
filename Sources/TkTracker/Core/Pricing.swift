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

    /// OpenAI billing: cached input at 10% of input, no cache-write charge
    /// (Codex usage never reports cache-write tokens).
    static func openAI(input: Double, output: Double) -> ModelPricing {
        ModelPricing(input: input, output: output, cacheRead: input * 0.1, cacheWrite5m: 0, cacheWrite1h: 0)
    }

    init(input: Double, output: Double, cacheRead: Double, cacheWrite5m: Double, cacheWrite1h: Double) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
    }
}

enum Pricing {
    /// Web search billed per request, on top of tokens.
    static var webSearchPer1000: Double { PricingCatalog.shared.webSearchPer1000 }

    /// Substring-matched so bare ids, dated ids and bedrock/vertex-style ids all
    /// resolve; rules are ordered most-specific-first. The table itself lives in
    /// `pricing.json` — see `PricingCatalog`.
    static func pricing(for model: String) -> ModelPricing? {
        PricingCatalog.shared.pricing(for: model)
    }

    @inline(never)
    static func cost(model: String, totals: TokenTotals, context: PricingContext? = nil) -> Double {
        guard let p = PricingCatalog.shared.pricing(for: model, context: context) else { return 0 }
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
    static func cacheSavings(model: String, totals: TokenTotals, context: PricingContext? = nil) -> Double {
        guard let p = PricingCatalog.shared.pricing(for: model, context: context) else { return 0 }
        let mtok = 1_000_000.0
        let promptTokens = Double(totals.input) + Double(totals.cacheRead) + Double(totals.cacheWrite5m) + Double(totals.cacheWrite1h)
        let uncached = promptTokens / mtok * p.input
        let actual = Double(totals.input) / mtok * p.input
            + Double(totals.cacheRead) / mtok * p.cacheRead
            + Double(totals.cacheWrite5m) / mtok * p.cacheWrite5m
            + Double(totals.cacheWrite1h) / mtok * p.cacheWrite1h
        return uncached - actual
    }

    /// Context window used for the session context gauge when the session's own
    /// usage events don't report one (Codex does; that value wins). Claude Code
    /// appends "[1m]" to the model id when the 1M-token window is active;
    /// GPT-5-family models run a ~272K input window; everything else the
    /// standard 200K.
    static func contextWindow(for model: String) -> Int64 {
        PricingCatalog.shared.contextWindow(for: model)
    }
}

/// Model family, used for stable chart colors and grouping.
enum ModelFamily: String, CaseIterable, Codable, Sendable {
    case fable = "Fable"
    case sonnet = "Sonnet"
    case opus = "Opus"
    case haiku = "Haiku"
    case gpt = "GPT"
    case other = "Other"

    init(model: String) {
        let m = model.lowercased()
        if m.contains("gpt") || m.contains("codex") { self = .gpt }
        else if m.contains("fable") || m.contains("mythos") { self = .fable }
        else if m.contains("opus") { self = .opus }
        else if m.contains("sonnet") { self = .sonnet }
        else if m.contains("haiku") { self = .haiku }
        else { self = .other }
    }

    /// Fixed stacking/legend order — validated for CVD-safe adjacency in both color modes.
    static let displayOrder: [ModelFamily] = [.fable, .sonnet, .opus, .haiku, .gpt, .other]

    /// Short display name for a full model id, e.g. "claude-opus-4-8" -> "Opus 4.8",
    /// "gpt-5.3-codex" -> "Codex 5.3".
    static func shortName(for model: String) -> String {
        ModelIdentity.displayName(model)
    }

    /// Numeric generation for ordering within a family: "claude-opus-4-8" -> 4.8,
    /// "gpt-5.5" -> 5.5.
    static func version(of model: String) -> Double {
        if ModelFamily(model: model) == .gpt {
            return dottedVersion(model.lowercased()) ?? 0
        }
        return Double(versionDigits(model).prefix(2).joined(separator: ".")) ?? 0
    }

    /// Version fragments like "4-8" or "5" from a model id (date suffixes excluded).
    private static func versionDigits(_ model: String) -> [String] {
        model.lowercased().split(separator: "-").compactMap { part -> String? in
            guard part.count <= 2, part.allSatisfy(\.isNumber) else { return nil }
            return String(part)
        }
    }

    /// OpenAI ids version with dots inside one segment ("gpt-5.5", "gpt-5.3-codex").
    private static func dottedVersion(_ model: String) -> Double? {
        for part in model.split(whereSeparator: { $0 == "-" || $0 == "_" }) {
            guard part.count <= 4, part.contains(where: \.isNumber),
                  part.allSatisfy({ $0.isNumber || $0 == "." }),
                  let value = Double(part)
            else { continue }
            return value
        }
        return nil
    }

    /// "5.0" -> "5", "5.50" -> "5.5" for display.
    private static func trimmedVersion(_ value: Double) -> String {
        var s = String(format: "%.2f", value)
        while s.contains("."), s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
