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
    static let webSearchPer1000: Double = 10.0

    /// Substring-matched so bare ids, dated ids and bedrock/vertex-style ids all resolve.
    /// Order matters: most specific first.
    static func pricing(for model: String) -> ModelPricing? {
        let m = model.lowercased()
        if m.isEmpty || m.contains("synthetic") { return nil }
        // OpenAI (Codex sessions) — list prices per MTok, standard tier.
        // gpt-5.4/5.5 long-context premiums are not modeled (like [1m] Sonnet,
        // sessions run the standard window unless the prompt exceeds it).
        if m.contains("gpt") || m.contains("codex") {
            if m.contains("codex-mini-latest") { return .openAI(input: 1.5, output: 6) } // pre-GPT-5 codex
            if m.contains("codex-mini") { return .openAI(input: 0.25, output: 2) } // gpt-5.1-codex-mini
            if m.contains("gpt-5.5") { return .openAI(input: 5, output: 30) }
            if m.contains("gpt-5.4-mini") { return .openAI(input: 0.75, output: 4.5) }
            if m.contains("gpt-5.4-nano") { return .openAI(input: 0.20, output: 1.25) }
            if m.contains("gpt-5.4") { return .openAI(input: 2.5, output: 15) }
            if m.contains("gpt-5.3") { return .openAI(input: 1.75, output: 14) } // gpt-5.3-codex
            if m.contains("gpt-5.2") { return .openAI(input: 0.875, output: 7) }
            if m.contains("gpt-5"), m.contains("mini") { return .openAI(input: 0.25, output: 2) } // gpt-5-mini / 5.1-mini
            if m.contains("gpt-5"), m.contains("nano") { return .openAI(input: 0.05, output: 0.40) }
            if m.contains("gpt-5") { return .openAI(input: 1.25, output: 10) } // gpt-5 / 5.1 (+codex, max)
            return nil // unknown generations surface as "no pricing", never a guess
        }
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

    /// Context window used for the session context gauge when the session's own
    /// usage events don't report one (Codex does; that value wins). Claude Code
    /// appends "[1m]" to the model id when the 1M-token window is active;
    /// GPT-5-family models run a ~272K input window; everything else the
    /// standard 200K.
    static func contextWindow(for model: String) -> Int64 {
        let m = model.lowercased()
        if m.contains("[1m]") { return 1_000_000 }
        if m.contains("gpt") || m.contains("codex") { return 272_000 }
        return 200_000
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
        let family = ModelFamily(model: model)
        switch family {
        case .other:
            return model
        case .gpt:
            let m = model.lowercased()
            let version = dottedVersion(m).map { trimmedVersion($0) }
            let base: String
            if m.contains("codex"), m.contains("mini") { base = "Codex Mini" }
            else if m.contains("codex") { base = "Codex" }
            else { base = version == nil ? "GPT" : "GPT-" }
            guard let version else { return base }
            return base.hasSuffix("-") ? base + version : "\(base) \(version)"
        default:
            let version = versionDigits(model).prefix(2).joined(separator: ".")
            return version.isEmpty ? family.rawValue : "\(family.rawValue) \(version)"
        }
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
