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
    var ids: [String]?
    var cacheRead: Double?
    var cacheWrite5m: Double?
    var cacheWrite1h: Double?
    var contextWindow: Int64?
    var longContextThreshold: Int64?
    var fastMultiplier: Double?
    var validFrom: String?
    var validUntil: String?
    var reviewAfter: String?
    var sourceURL: String?

    func matches(_ id: String, at date: Date?) -> Bool {
        guard ids?.contains(id) ?? match.allSatisfy({ id.contains($0) }) else { return false }
        if validFrom == nil && validUntil == nil { return true }
        let day = ISO8601DateFormatter().string(from: date ?? Date()).prefix(10)
        if let validFrom, day < validFrom { return false }
        if let validUntil, day >= validUntil { return false }
        return true
    }
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

    static let currentSchema = 2
}

/// Anchor for `Bundle(for:)`, so resource lookup can be relative to this
/// module's own code rather than to `Bundle.main` (which is the test runner
/// under `swift test`).
private final class BundleAnchor {}

/// A user-supplied correction for one model, keyed by its short display name
/// ("Opus 4.8") so it covers every dated id that resolves to that name.
struct PricingOverride: Codable, Sendable, Equatable {
    var input: Double
    var output: Double
    var cacheRead: Double?
    var cacheWrite5m: Double?
    var cacheWrite1h: Double?

    var isValid: Bool {
        [input, output, cacheRead, cacheWrite5m, cacheWrite1h].compactMap { $0 }.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1_000_000 }
    }
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
    /// The process-wide catalog every cost calculation resolves through.
    ///
    /// Under test it is built with **no overrides**. Otherwise every money
    /// assertion in the suite — including the golden corpus whose entire point is
    /// being hand-derived and reproducible — would read whatever overrides happen
    /// to be sitting in the developer's Application Support directory, and would
    /// pass or fail depending on ambient machine state. Tests that want to
    /// exercise overrides construct their own instance with an injected path.
    static let shared = PricingCatalog(overrides: isRunningTests ? [:] : nil)

    /// True when hosted by a test runner.
    ///
    /// Several signals because no single one covers every host: XCTest exposes a
    /// class and an env var, while `swift test` with swift-testing on a
    /// Command-Line-Tools toolchain exposes neither — it runs under
    /// `swiftpm-testing-helper` with an empty environment. `FormatAndResourceTests`
    /// asserts this returns true, so if a future toolchain slips past every
    /// check the suite fails loudly instead of silently reading ambient state.
    /// `TKTRACKER_NO_PRICING_OVERRIDES` is the explicit escape hatch.
    static var isRunningTests: Bool {
        let info = ProcessInfo.processInfo
        if info.environment["TKTRACKER_NO_PRICING_OVERRIDES"] != nil { return true }
        if info.environment["XCTestConfigurationFilePath"] != nil { return true }
        if NSClassFromString("XCTestCase") != nil { return true }
        let host = info.processName
        if host == "swiftpm-testing-helper" || host == "xctest" || host.hasSuffix("PackageTests") {
            return true
        }
        if info.arguments.contains(where: { $0.hasSuffix(".xctest") }) { return true }
        return Bundle.allBundles.contains { $0.bundleURL.pathExtension == "xctest" }
    }

    private let lock = NSLock()
    private var document: PricingDocument
    private var overrides: [String: PricingOverride]
    /// Memoized id → price. Substring matching is the hot path of every cost
    /// calculation; models per machine number in the dozens.
    private var resolved: [String: ModelPricing?] = [:]
    private var canonicalIDs: [String: String] = [:]
    private var persistenceError: String?
    var lastError: String? { lock.lock(); defer { lock.unlock() }; return persistenceError }
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

    @inline(never)
    func pricing(for model: String, context: PricingContext? = nil) -> ModelPricing? {
        lock.lock()
        defer { lock.unlock() }
        let id: String
        if let cached = canonicalIDs[model] { id = cached }
        else {
            id = ModelIdentity.canonical(model)
            if canonicalIDs.count > 512 { canonicalIDs.removeAll(keepingCapacity: true) }
            canonicalIDs[model] = id
        }
        let day = Int64((context?.date ?? Date()).timeIntervalSince1970 / 86400)
        let band = document.rules.compactMap(\.longContextThreshold).filter { (context?.promptTokens ?? 0) > $0 }.count
        let key = "\(id)|\(day)|\(context?.tier.rawValue ?? "unknown")|\(band)|\(context?.regional ?? false)"
        // Every rate-changing dimension participates in this bounded memo.
        if let hit = resolved[key] { return hit }
        let value = compute(for: id, context: context)
        if resolved.count > 4096 { resolved.removeAll(keepingCapacity: true) }
        resolved[key] = .some(value)
        return value
    }

    @inline(never)
    private func compute(for model: String, context: PricingContext?) -> ModelPricing? {
        let id = model
        guard !id.isEmpty, !id.contains("synthetic") else { return nil }
        let matched = document.rules.first { $0.matches(id, at: context?.date) }
        let vendor = matched?.vendor ?? Self.vendor(for: id)
        // Read legacy labels only when they describe this exact variant. New
        // writes always use canonical IDs; e.g. a GPT-5.4 override cannot leak
        // into Mini/Nano, whose display labels are now distinct.
        let override = overrides[id] ?? overrides[ModelIdentity.displayName(id)]
        if matched?.skip == true { return nil }
        guard let input = override?.input ?? matched?.input,
              let output = override?.output ?? matched?.output else { return nil }
        let defaults = Self.makePricing(input: input, output: output, vendor: vendor)
        func inherited(_ value: Double?, fallback: Double) -> Double {
            guard let value else { return fallback }
            if override != nil, let original = matched?.input, original > 0 { return value * input / original }
            return value
        }
        var p = ModelPricing(input: input, output: output,
            cacheRead: override?.cacheRead ?? inherited(matched?.cacheRead, fallback: defaults.cacheRead),
            cacheWrite5m: override?.cacheWrite5m ?? inherited(matched?.cacheWrite5m, fallback: defaults.cacheWrite5m),
            cacheWrite1h: override?.cacheWrite1h ?? inherited(matched?.cacheWrite1h, fallback: defaults.cacheWrite1h))
        guard [p.input, p.output, p.cacheRead, p.cacheWrite5m, p.cacheWrite1h].allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        var inputMultiplier = 1.0
        var outputMultiplier = 1.0
        if let threshold = matched?.longContextThreshold, let prompt = context?.promptTokens, prompt > threshold {
            inputMultiplier = 2
            outputMultiplier = 1.5
        }
        let tier = context?.tier ?? .unknown
        let multiplier: Double
        switch tier {
        case .fast:
            guard let fast = matched?.fastMultiplier else { return nil }
            multiplier = fast
        case .batch: multiplier = 0.5
        case .flex:
            guard vendor == "openai" else { return nil }
            multiplier = 0.5
        default: multiplier = 1
        }
        let region = context?.regional == true ? 1.1 : 1
        inputMultiplier *= multiplier * region
        outputMultiplier *= multiplier * region
        p = ModelPricing(input: p.input * inputMultiplier, output: p.output * outputMultiplier,
                         cacheRead: p.cacheRead * inputMultiplier,
                         cacheWrite5m: p.cacheWrite5m * inputMultiplier,
                         cacheWrite1h: p.cacheWrite1h * inputMultiplier)
        return p
    }

    var updated: String { document.updated ?? "unknown" }
    var knownModels: [String] { document.rules.flatMap { $0.ids ?? [] }.sorted() }

    func reviewNotice(at now: Date = Date()) -> String? {
        let day = String(ISO8601DateFormatter().string(from: now).prefix(10))
        let due = document.rules.filter { $0.reviewAfter.map { day >= $0 } ?? false }.flatMap { $0.ids ?? [] }
        if !due.isEmpty { return "Promotional rates need review: " + due.map(ModelIdentity.displayName).joined(separator: ", ") }
        if let updated = document.updated,
           let checked = ISO8601DateFormatter().date(from: updated + "T00:00:00Z"), now.timeIntervalSince(checked) > 90 * 86400 {
            return "This catalog was checked more than 90 days ago. Verify current vendor rates or install an update."
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
        let id = ModelIdentity.canonical(model)
        if model.contains("[1m]") { return 1_000_000 }
        if let window = document.rules.first(where: { $0.matches(id, at: nil) })?.contextWindow { return window }
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
        let previous = overrides
        persistenceError = nil
        if let override {
            guard override.isValid else { persistenceError = "Rates must be finite and nonnegative."; lock.unlock(); return }
            overrides[name] = override
        } else {
            overrides.removeValue(forKey: name)
        }
        resolved.removeAll(keepingCapacity: true)
        let snapshot = overrides
        do { try Self.saveOverrides(snapshot, to: overridesURL) }
        catch { overrides = previous; persistenceError = error.localizedDescription }
        lock.unlock()
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
        return decoded.filter { $0.value.isValid }
    }

    private static func saveOverrides(_ overrides: [String: PricingOverride], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(overrides)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Loading

    /// Locates a resource in the SwiftPM resource bundle **without** `Bundle.module`.
    ///
    /// `Bundle.module` cannot be used here. SwiftPM's generated accessor calls
    /// `Swift.fatalError` when it cannot find the bundle, so it never returns
    /// nil and the documented "fall back to the compiled-in table" path was
    /// unreachable — the app would trap instead. It also looks for the bundle at
    /// `Bundle.main.bundleURL/TkTracker_TkTracker.bundle`, which inside a `.app`
    /// is the app *root*, whereas the conventional location (and the one
    /// `make app` uses) is `Contents/Resources`. Both defects were invisible on
    /// the build machine because the generated accessor also carries a hardcoded
    /// absolute `.build` path, which exists only there.
    ///
    /// So: probe the plausible locations, and return nil rather than trapping.
    static func resourceURL(named name: String, extension ext: String) -> URL? {
        let bundleName = "TkTracker_TkTracker.bundle"
        var roots: [URL] = []
        // Inside a .app: Contents/Resources.
        if let resources = Bundle.main.resourceURL { roots.append(resources) }
        // Beside the executable: `swift run`, a bare binary.
        if let executableDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            roots.append(executableDir)
        }
        // The bundle root itself, which is what Bundle.module would have used.
        roots.append(Bundle.main.bundleURL)
        // Anchored on this module's own code rather than on Bundle.main. Under
        // `swift test` Bundle.main is the test runner, so none of the above find
        // the executable target's resource bundle — but the bundle carrying this
        // class sits next to it in .build.
        let anchor = Bundle(for: BundleAnchor.self).bundleURL
        roots.append(anchor)
        roots.append(anchor.deletingLastPathComponent())

        for root in roots {
            let candidate = root.appendingPathComponent(bundleName)
            if let bundle = Bundle(url: candidate),
               let url = bundle.url(forResource: name, withExtension: ext) {
                return url
            }
        }
        // Resources flattened straight into the main bundle.
        return Bundle.main.url(forResource: name, withExtension: ext)
    }

    private static func loadBundled() -> PricingDocument? {
        guard let url = resourceURL(named: "pricing", extension: "json") else {
            return nil
        }
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

    // Generated from pricing.json by Scripts/generate_pricing.py; CI checks drift.
    static let builtIn = try! JSONDecoder().decode(PricingDocument.self, from: Data(BundledPricing.json.utf8))
}
