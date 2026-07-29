import Foundation

/// One ordered pricing rule: every substring in `match` must appear in the
/// lowercased model id for the rule to apply.
struct PricingRule: Codable, Sendable {
    var match: [String]
    var vendor: String?
    var input: Double?
    var output: Double?
    /// Deliberately unpriced — tracked in tokens and flagged "no pricing" rather
    /// than guessed at from a neighbouring generation.
    var skip: Bool?
    var comment: String?
}

struct ContextWindowRule: Codable, Sendable {
    var match: [String]
    var window: Int64
}

/// The shape of `pricing.json`.
struct PricingDocument: Codable, Sendable {
    var schema: Int
    var updated: String?
    var webSearchPer1000: Double
    var contextWindows: [ContextWindowRule]
    var defaultContextWindow: Int64
    var rules: [PricingRule]

    static let currentSchema = 1
}

/// A user-supplied correction for one model, keyed by its short display name
/// ("Opus 4.8") so it covers every dated id that resolves to that name.
struct PricingOverride: Codable, Sendable, Equatable {
    var input: Double
    var output: Double
}

/// Resolves model ids to prices.
///
/// The rates used to live as a hardcoded `if id.contains(…)` chain in Swift,
/// which meant every vendor price change shipped as a full app release — the
/// highest-churn data in the app living in its least updatable place. They now
/// come from a bundled `pricing.json`, with the old chain kept as a compiled-in
/// fallback so the CLI, tests and any build without the resource bundle behave
/// identically.
///
/// Users can override any model's rate (Settings → Pricing) to correct a stale
/// figure or to reflect negotiated rates without waiting for a release.
final class PricingCatalog: @unchecked Sendable {
    static let shared = PricingCatalog()

    private let lock = NSLock()
    private var document: PricingDocument
    private var overrides: [String: PricingOverride]
    /// Memoized id → price. Substring matching is the hot path of every cost
    /// calculation; models per machine number in the dozens.
    private var resolved: [String: ModelPricing?] = [:]
    /// Where overrides persist. Injectable so a test never reads — or writes —
    /// the real user file in Application Support.
    private let overridesURL: URL

    private(set) var loadedFromBundle = false

    init(
        document: PricingDocument? = nil,
        overrides: [String: PricingOverride]? = nil,
        overridesURL: URL? = nil
    ) {
        if let document {
            self.document = document
        } else if let bundled = Self.loadBundled() {
            self.document = bundled
            loadedFromBundle = true
        } else {
            Diagnostics.pricing.notice("pricing.json unavailable; using compiled-in table")
            self.document = Self.builtIn
        }
        let url = overridesURL ?? Self.defaultOverridesURL()
        self.overridesURL = url
        self.overrides = overrides ?? Self.loadOverrides(from: url)
    }

    // MARK: - Lookup

    func pricing(for model: String) -> ModelPricing? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = resolved[model] { return cached }
        let value = compute(for: model)
        resolved[model] = value
        return value
    }

    /// Assumes the lock is held.
    private func compute(for model: String) -> ModelPricing? {
        let id = model.lowercased()
        guard !id.isEmpty else { return nil }

        let vendor = Self.vendor(for: id)
        if let override = overrides[ModelFamily.shortName(for: model)] {
            return Self.makePricing(input: override.input, output: override.output, vendor: vendor)
        }

        for rule in document.rules where rule.match.allSatisfy({ id.contains($0) }) {
            if rule.skip == true { return nil }
            guard let input = rule.input, let output = rule.output else { return nil }
            return Self.makePricing(input: input, output: output, vendor: rule.vendor ?? vendor)
        }
        return nil
    }

    var webSearchPer1000: Double {
        lock.lock()
        defer { lock.unlock() }
        return document.webSearchPer1000
    }

    func contextWindow(for model: String) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        let id = model.lowercased()
        for rule in document.contextWindows where rule.match.allSatisfy({ id.contains($0) }) {
            return rule.window
        }
        return document.defaultContextWindow
    }

    /// "openai" for GPT/Codex ids, "anthropic" otherwise — decides which cache
    /// multipliers apply when a rule doesn't state a vendor.
    private static func vendor(for lowercasedId: String) -> String {
        (lowercasedId.contains("gpt") || lowercasedId.contains("codex")) ? "openai" : "anthropic"
    }

    private static func makePricing(input: Double, output: Double, vendor: String) -> ModelPricing {
        vendor == "openai"
            ? .openAI(input: input, output: output)
            : ModelPricing(input: input, output: output)
    }

    // MARK: - Overrides

    var overrideCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return overrides.count
    }

    func override(forShortName name: String) -> PricingOverride? {
        lock.lock()
        defer { lock.unlock() }
        return overrides[name]
    }

    var allOverrides: [String: PricingOverride] {
        lock.lock()
        defer { lock.unlock() }
        return overrides
    }

    /// Set or clear (nil) a model's rate. Invalidates the memo so the next cost
    /// calculation reflects it immediately.
    func setOverride(_ override: PricingOverride?, forShortName name: String) {
        lock.lock()
        if let override {
            overrides[name] = override
        } else {
            overrides.removeValue(forKey: name)
        }
        resolved.removeAll(keepingCapacity: true)
        let snapshot = overrides
        lock.unlock()
        Self.saveOverrides(snapshot, to: overridesURL)
        Diagnostics.pricing.notice("pricing override \(override == nil ? "cleared" : "set") for \(name, privacy: .public)")
    }

    static func defaultOverridesURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("TkTracker/pricing-overrides.json")
    }

    private static func loadOverrides(from url: URL) -> [String: PricingOverride] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: PricingOverride].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func saveOverrides(_ overrides: [String: PricingOverride], to url: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(overrides)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            Diagnostics.pricing.error("could not save pricing overrides: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Loading

    private static func loadBundled() -> PricingDocument? {
        guard let url = Bundle.module.url(forResource: "pricing", withExtension: "json") else { return nil }
        do {
            let document = try JSONDecoder().decode(PricingDocument.self, from: Data(contentsOf: url))
            guard document.schema == PricingDocument.currentSchema else {
                Diagnostics.pricing.error("pricing.json schema \(document.schema) unsupported; using compiled-in table")
                return nil
            }
            return document
        } catch {
            Diagnostics.pricing.error("pricing.json unreadable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The pre-1.5 hardcoded table, kept verbatim as a fallback. Any build that
    /// cannot reach the resource bundle prices exactly as before.
    static let builtIn = PricingDocument(
        schema: PricingDocument.currentSchema,
        updated: "built-in",
        webSearchPer1000: 10.0,
        contextWindows: [
            ContextWindowRule(match: ["[1m]"], window: 1_000_000),
            ContextWindowRule(match: ["gpt"], window: 272_000),
            ContextWindowRule(match: ["codex"], window: 272_000),
        ],
        defaultContextWindow: 200_000,
        rules: [
            PricingRule(match: ["synthetic"], skip: true),
            PricingRule(match: ["codex-mini-latest"], vendor: "openai", input: 1.5, output: 6),
            PricingRule(match: ["codex-mini"], vendor: "openai", input: 0.25, output: 2),
            PricingRule(match: ["gpt-5.5"], vendor: "openai", input: 5, output: 30),
            PricingRule(match: ["gpt-5.4-mini"], vendor: "openai", input: 0.75, output: 4.5),
            PricingRule(match: ["gpt-5.4-nano"], vendor: "openai", input: 0.20, output: 1.25),
            PricingRule(match: ["gpt-5.4"], vendor: "openai", input: 2.5, output: 15),
            PricingRule(match: ["gpt-5.3"], vendor: "openai", input: 1.75, output: 14),
            PricingRule(match: ["gpt-5.2"], vendor: "openai", input: 0.875, output: 7),
            PricingRule(match: ["gpt-5", "mini"], vendor: "openai", input: 0.25, output: 2),
            PricingRule(match: ["gpt-5", "nano"], vendor: "openai", input: 0.05, output: 0.40),
            PricingRule(match: ["gpt-5"], vendor: "openai", input: 1.25, output: 10),
            PricingRule(match: ["gpt"], skip: true),
            PricingRule(match: ["codex"], skip: true),
            PricingRule(match: ["fable"], vendor: "anthropic", input: 10, output: 50),
            PricingRule(match: ["mythos"], vendor: "anthropic", input: 10, output: 50),
            PricingRule(match: ["opus-4-5"], vendor: "anthropic", input: 5, output: 25),
            PricingRule(match: ["opus-4-6"], vendor: "anthropic", input: 5, output: 25),
            PricingRule(match: ["opus-4-7"], vendor: "anthropic", input: 5, output: 25),
            PricingRule(match: ["opus-4-8"], vendor: "anthropic", input: 5, output: 25),
            PricingRule(match: ["opus"], vendor: "anthropic", input: 15, output: 75),
            PricingRule(match: ["sonnet"], vendor: "anthropic", input: 3, output: 15),
            PricingRule(match: ["haiku-4"], vendor: "anthropic", input: 1, output: 5),
            PricingRule(match: ["3-5-haiku"], vendor: "anthropic", input: 0.8, output: 4),
            PricingRule(match: ["haiku-3-5"], vendor: "anthropic", input: 0.8, output: 4),
            PricingRule(match: ["haiku"], vendor: "anthropic", input: 0.25, output: 1.25),
            PricingRule(match: ["claude-2"], vendor: "anthropic", input: 8, output: 24),
            PricingRule(match: ["instant"], vendor: "anthropic", input: 0.8, output: 2.4),
        ]
    )
}
