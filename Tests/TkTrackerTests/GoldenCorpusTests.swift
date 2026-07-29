import Testing
import Foundation
@testable import TkTracker

/// End-to-end check against a committed corpus whose expected values were
/// derived by hand from published rates — see `Fixtures/EXPECTED.md`.
///
/// The README claims both pipelines are "verified against an independent
/// reference implementation over real data". That verification was real but
/// lived on one machine and could not be re-run in CI. This is the reproducible
/// part of that claim: small enough to commit, exact enough that every figure
/// can be checked with a calculator, and covering the properties that actually
/// break silently — dedupe within a file, the cross-file claim table, cache
/// tiers at their real multipliers, web-search billing, Codex's cached-input
/// split, and Claude/Codex merging into one project.
@Suite("Golden corpus")
struct GoldenCorpusTests {
    private let claudeRoot: URL
    private let codexRoot: URL
    private let scratch: URL

    init() throws {
        let fixtures = try #require(
            Bundle.module.url(forResource: "Fixtures", withExtension: nil),
            "Fixtures resource directory missing from the test bundle"
        )
        let fm = FileManager.default
        let raw = fm.temporaryDirectory
            .appendingPathComponent("tktracker-golden-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: raw, withIntermediateDirectories: true)
        // /var is a symlink to /private/var, and digests record the canonical
        // path the enumerator reports. Seeded claim owners have to match that
        // exactly or they refuse every file instead of pinning one.
        scratch = URL(fileURLWithPath: ScanCore.canonicalPath(raw), isDirectory: true)

        // Read from a scratch copy so the bundle stays pristine and the scan
        // writes its caches somewhere disposable.
        claudeRoot = scratch.appendingPathComponent("claude", isDirectory: true)
        codexRoot = scratch.appendingPathComponent("codex", isDirectory: true)
        try fm.copyItem(at: fixtures.appendingPathComponent("claude"), to: claudeRoot)
        try fm.copyItem(at: fixtures.appendingPathComponent("codex"), to: codexRoot)
    }

    private var s1Path: String {
        claudeRoot
            .appendingPathComponent("-Users-x-Documents-golden", isDirectory: true)
            .appendingPathComponent("s1.jsonl").path
    }

    /// Scans both sources.
    ///
    /// `claims` matters for the per-session assertions. On a *cold* scan the
    /// files are parsed concurrently, so which session wins the shared
    /// `m1`/`r1` message is a genuine race — sorting oldest-first only biases
    /// the dispatch order, it does not decide the winner. Totals are invariant
    /// either way, but attribution is not, so tests that assert per-session
    /// costs pass the claim the persisted cache would already hold.
    private func digests(claims: ClaimMap = ClaimMap()) -> [FileDigest] {
        let claude = ScanCore(
            source: .claude,
            root: claudeRoot,
            cacheURL: scratch.appendingPathComponent("claude.json")
        )
        let codex = ScanCore(
            source: .codex,
            root: codexRoot,
            cacheURL: scratch.appendingPathComponent("codex.json")
        )
        let c = claude.refreshed(digests: [:], claims: claims)
        let x = codex.refreshed(digests: [:], claims: ClaimMap())
        return Array(c.digests.values) + Array(x.digests.values)
    }

    /// Digests with ownership pinned to `s1`, as it would be after the original
    /// session was scanned before the resume existed.
    private func settledDigests() -> [FileDigest] {
        digests(claims: ["m1:r1": s1Path])
    }

    // Within 1/100th of a cent: the inputs are round millions, so any real
    // regression moves these by dollars, not rounding.
    private func expectMoney(_ actual: Double, _ expected: Double, _ what: String) {
        #expect(abs(actual - expected) < 0.0001, "\(what): got \(actual), expected \(expected)")
    }

    @Test func claudeMatchesHandDerivedTotals() throws {
        let claude = settledDigests().filter { $0.source == .claude }
        #expect(claude.count == 2)

        var totals = TokenTotals()
        var cost = 0.0
        for digest in claude {
            totals.add(digest.totals)
            cost += digest.cost
        }

        // Dedupe (within s1) and the claim table (s1 vs s2) both hold, or these
        // come out at 13,000,000 / 5 / $112.50.
        #expect(totals.total == 8_000_000)
        #expect(totals.messages == 3)
        expectMoney(cost, 65.75, "Claude total")

        let s1 = claude.first { $0.path.hasSuffix("s1.jsonl") }
        let s2 = claude.first { $0.path.hasSuffix("s2.jsonl") }
        expectMoney(s1?.cost ?? 0, 59.75, "s1")
        expectMoney(s2?.cost ?? 0, 6.00, "s2")
        #expect(s1?.totals.messages == 2)
        #expect(s2?.totals.messages == 1)

        // Every cache tier billed at its own multiplier.
        #expect(s1?.totals.cacheRead == 1_000_000)
        #expect(s1?.totals.cacheWrite5m == 1_000_000)
        #expect(s1?.totals.cacheWrite1h == 1_000_000)
        #expect(s1?.totals.webSearches == 1_000)
    }

    @Test func codexMatchesHandDerivedTotals() throws {
        let codex = digests().filter { $0.source == .codex }
        let rollout = try #require(codex.first)

        // input_tokens is inclusive of cached; the parser must split it.
        #expect(rollout.totals.input == 500_000)
        #expect(rollout.totals.cacheRead == 500_000)
        #expect(rollout.totals.output == 1_000_000)
        #expect(rollout.totals.total == 2_000_000)
        #expect(rollout.totals.messages == 1)
        expectMoney(rollout.cost, 32.75, "Codex rollout")

        // The window the session reported wins over the per-model table.
        #expect(rollout.contextWindow == 272_000)
    }

    @Test func combinedStatsMatch() throws {
        // `.all` with a fixed `now` after the fixture timestamps, so the range
        // never clips and the test can't drift with the wall clock.
        let now = Date(timeIntervalSince1970: 1_783_000_000)
        let stats = StatsBuilder.build(digests: digests(), range: .all, now: now)

        #expect(stats.totals.total == 10_000_000)
        #expect(stats.totals.messages == 4)
        expectMoney(stats.cost, 98.50, "combined")
        expectMoney(stats.cost(for: .claude), 65.75, "claude share")
        expectMoney(stats.cost(for: .codex), 32.75, "codex share")

        // Both tools worked in the same directory, so they merge into one project.
        #expect(stats.projects.count == 1)
        #expect(stats.projects.first?.name == "golden")
        #expect(stats.projects.first?.sessions == 3)

        // Four distinct models, each priced.
        #expect(Set(stats.models.map(\.shortName)) == ["Opus 4.8", "Sonnet 4.5", "Haiku 4.5", "GPT-5.5"])
        let unpriced = stats.models.filter { !$0.hasPricing }.map(\.model)
        #expect(unpriced.isEmpty, "every fixture model should resolve a price, got \(unpriced)")
    }

    @Test func branchAttributionSplitsTheProject() throws {
        // Branch totals follow claim ownership, so this needs the settled state.
        let now = Date(timeIntervalSince1970: 1_783_000_000)
        let stats = StatsBuilder.build(digests: settledDigests(), range: .all, now: now)

        let byBranch = Dictionary(
            stats.branches.map { ($0.branch, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // main covers s1 (Claude) and the Codex rollout; feature/golden is s2.
        expectMoney(byBranch["main"]?.cost ?? 0, 59.75 + 32.75, "main branch")
        expectMoney(byBranch["feature/golden"]?.cost ?? 0, 6.00, "feature branch")
    }

    /// Overrides are exercised on a *local* catalog, never `PricingCatalog.shared`.
    ///
    /// The shared instance is process-global and persists to the real
    /// `~/Library/Application Support/TkTracker/pricing-overrides.json`, so
    /// mutating it from a test both raced the other tests running in parallel
    /// and rewrote the developer's own settings.
    @Test func pricingOverridesApplyAndPersist() throws {
        let overridesURL = scratch.appendingPathComponent("overrides.json")
        let catalog = PricingCatalog(
            document: PricingCatalog.builtIn,
            overrides: [:],
            overridesURL: overridesURL
        )

        let base = try #require(catalog.pricing(for: "claude-haiku-4-5"))
        #expect(base.input == 1)
        #expect(base.output == 5)

        catalog.setOverride(PricingOverride(input: 2, output: 10), forShortName: "Haiku 4.5")
        let overridden = try #require(catalog.pricing(for: "claude-haiku-4-5"))
        #expect(overridden.input == 2)
        #expect(overridden.output == 10)
        // Cache multipliers still derive from the vendor, not the override.
        #expect(overridden.cacheRead == 0.2)

        // A dated id resolving to the same short name picks the override up too.
        #expect(catalog.pricing(for: "claude-haiku-4-5-20251001")?.input == 2)
        // Other models are untouched.
        #expect(catalog.pricing(for: "claude-opus-4-8")?.input == 5)

        // Persisted, and reloaded by a fresh catalog over the same file.
        #expect(FileManager.default.fileExists(atPath: overridesURL.path))
        let reloaded = PricingCatalog(document: PricingCatalog.builtIn, overridesURL: overridesURL)
        #expect(reloaded.pricing(for: "claude-haiku-4-5")?.input == 2)
        #expect(reloaded.overrideCount == 1)

        catalog.setOverride(nil, forShortName: "Haiku 4.5")
        #expect(catalog.pricing(for: "claude-haiku-4-5")?.input == 1)
        #expect(catalog.overrideCount == 0)
    }

    @Test func bundledPricingMatchesTheCompiledInFallback() throws {
        // pricing.json and PricingCatalog.builtIn must agree, or the app and the
        // CLI price differently depending on whether the bundle is reachable.
        let bundled = PricingCatalog(overrides: [:], overridesURL: scratch.appendingPathComponent("a.json"))
        let fallback = PricingCatalog(
            document: PricingCatalog.builtIn,
            overrides: [:],
            overridesURL: scratch.appendingPathComponent("b.json")
        )
        #expect(bundled.loadedFromBundle, "pricing.json should be reachable from the test bundle")

        let ids = [
            "claude-opus-4-8", "claude-opus-4-1", "claude-sonnet-4-5", "claude-haiku-4-5",
            "claude-3-5-haiku-20241022", "claude-fable-5", "claude-2.1", "claude-instant-1.2",
            "gpt-5.5", "gpt-5.4", "gpt-5.4-mini", "gpt-5.4-nano", "gpt-5.3-codex",
            "gpt-5.2", "gpt-5.1-codex-mini", "gpt-5-mini", "gpt-5-nano", "gpt-5",
            "codex-mini-latest", "gpt-6-imaginary", "some-unknown-model",
        ]
        for id in ids {
            #expect(bundled.pricing(for: id) == fallback.pricing(for: id), "rates disagree for \(id)")
            #expect(bundled.contextWindow(for: id) == fallback.contextWindow(for: id), "window disagrees for \(id)")
        }
        #expect(bundled.webSearchPer1000 == fallback.webSearchPer1000)
        #expect(bundled.contextWindow(for: "claude-sonnet-4-5[1m]") == 1_000_000)
    }
}
