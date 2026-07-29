import Testing
import Foundation
@testable import TkTracker

/// Coverage for the pieces the review found asserted-in-prose but untested:
/// number formatting, resource resolution, redaction, and the pure helpers
/// behind the new fixes.
@Suite("Format, resources and helpers")
struct FormatAndResourceTests {
    // MARK: - Money and percentages

    /// Locale-independent shape checks. The separator itself follows
    /// `Locale.current`, so assertions look at digits and magnitude suffixes
    /// rather than hardcoding "." — otherwise the suite would only pass in en_US.
    private func digitsOnly(_ s: String) -> String {
        s.filter { $0.isNumber }
    }

    @Test func moneyBracketsPickTheRightPrecision() {
        #expect(Format.money(0) == "$0")

        // Sub-cent keeps four decimals, trailing zeros trimmed ("0.0042").
        #expect(digitsOnly(Format.money(0.0042)) == "00042")
        // Under a dollar: three decimals ("0.420").
        #expect(digitsOnly(Format.money(0.42)) == "0420")
        // Under 100: two decimals.
        #expect(digitsOnly(Format.money(4.83)) == "483")
        #expect(digitsOnly(Format.money(48.30)) == "4830")
        // Under 1000: whole dollars.
        #expect(digitsOnly(Format.money(483.4)) == "483")
        // Thousands and millions get suffixes.
        #expect(Format.money(4_830).hasSuffix("K"))
        #expect(Format.money(4_830_000).hasSuffix("M"))
        // Every form is currency-prefixed.
        for value in [0.0042, 0.42, 4.83, 483.0, 4_830.0, 4_830_000.0] {
            #expect(Format.money(value).hasPrefix("$"), "no $ prefix for \(value)")
        }
    }

    @Test func negativeAmountsKeepTheSignReadable() {
        // A refund or a correction must not render as "$-" garbage or lose sign.
        for value in [-0.0042, -4.83, -483.0, -4_830.0] {
            let s = Format.money(value)
            #expect(s.contains("-"), "sign lost for \(value): \(s)")
        }
        #expect(Format.moneyCompact(-4.83).contains("-"))
    }

    @Test func compactMoneySuppressesGroupingForStableWidth() {
        // The menu bar re-renders constantly; a grouping separator appearing at
        // 1,000 would jitter the status item's width.
        let compact = Format.moneyCompact(4_830)
        #expect(compact.hasSuffix("K"))
        let mid = Format.moneyCompact(483)
        #expect(!mid.contains(","))
        #expect(!mid.contains("\u{202F}")) // narrow no-break space, used by fr
        #expect(!mid.contains("\u{00A0}"))
    }

    @Test func percentAndSignedPercent() {
        #expect(Format.percent(0) == "0%")
        #expect(Format.percent(0.005) == "<1%") // never rounds a nonzero to 0%
        #expect(Format.percent(0.84) == "84%")
        #expect(Format.percent(1) == "100%")
        #expect(Format.signedPercent(0.38).hasPrefix("+"))
        #expect(Format.signedPercent(-0.12).hasPrefix("-"))
        #expect(Format.signedPercent(0).hasPrefix("+"))
    }

    @Test func multipleFormatsCoarselyWhenLarge() {
        #expect(digitsOnly(Format.multiple(9.24)) == "92") // one decimal
        #expect(digitsOnly(Format.multiple(12.7)) == "13") // whole at >= 10
        #expect(Format.multiple(9.24).hasPrefix("×"))
    }

    @Test func tokenAndDurationFormatting() {
        #expect(Format.tokens(845) == "845")
        #expect(Format.tokens(12_400).hasSuffix("K"))
        #expect(Format.tokens(3_200_000).hasSuffix("M"))
        #expect(Format.tokens(1_400_000_000).hasSuffix("B"))

        #expect(Format.duration(0) == "0m")
        #expect(Format.duration(-99) == "0m") // clamps rather than showing negatives
        #expect(Format.duration(3600 * 2 + 300) == "2h 05m")
        #expect(Format.durationCompact(3600 * 2 + 300) == "2h05")
        #expect(Format.durationCompact(1860) == "31m")
    }

    /// The formatter cache is keyed by (min, max, grouping); a miss must degrade
    /// rather than produce nothing.
    @Test func formattingIsStableAcrossManyCalls() {
        // Guards the cached-formatter rewrite: a shared mutable formatter would
        // be sensitive to call order, so the same input must format identically
        // however many other shapes ran in between.
        let first = Format.money(4.83)
        _ = Format.money(0.0042)
        _ = Format.percent(0.5)
        _ = Format.tokens(12_400)
        _ = Format.moneyCompact(999)
        #expect(Format.money(4.83) == first)
    }

    // MARK: - Resource resolution

    @Test func bundledResourcesResolveWithoutTrapping() throws {
        // Regression guard for the defect that would have crashed every
        // non-developer machine: `Bundle.module` fatalErrors when it cannot find
        // the bundle, so the "fall back to the compiled-in table" contract was
        // unreachable. This must return a URL here, and must be nil-able rather
        // than trapping elsewhere.
        let pricing = PricingCatalog.resourceURL(named: "pricing", extension: "json")
        #expect(pricing != nil, "pricing.json must resolve from the test bundle")
        #expect(PricingCatalog.resourceURL(named: "definitely-not-here", extension: "json") == nil)

        // And the shipped table really is what the catalog is using.
        let catalog = PricingCatalog(
            overrides: [:],
            overridesURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("tk-\(UUID().uuidString).json")
        )
        #expect(catalog.loadedFromBundle)
    }

    @Test func sharedCatalogIgnoresAmbientOverridesUnderTest() {
        // The golden corpus's whole claim is that it is hand-derived and
        // reproducible. If `PricingCatalog.shared` picked up whatever overrides
        // sat in the developer's Application Support directory, every money
        // assertion in the suite would depend on ambient machine state.
        #expect(PricingCatalog.isRunningTests)
        #expect(PricingCatalog.shared.overrideCount == 0)
        #expect(PricingCatalog.shared.pricing(for: "claude-opus-4-8")?.input == 5)
    }

    @Test func overrideCannotResurrectASkippedModel() {
        // `skip: true` means "never guess a price". An override must not turn
        // Claude Code's synthetic placeholder turns into billable spend.
        let catalog = PricingCatalog(
            document: PricingCatalog.builtIn,
            overrides: ["Synthetic": PricingOverride(input: 99, output: 99)],
            overridesURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("tk-\(UUID().uuidString).json")
        )
        #expect(catalog.pricing(for: "<synthetic>") == nil)
        #expect(Pricing.cost(model: "<synthetic>", totals: TokenTotals(input: 1_000_000, messages: 1)) == 0)
    }

    // MARK: - Diagnostics redaction

    @Test func redactionKeepsNoPathContent() {
        // Settings promises the diagnostics report never includes project paths.
        let path = "/Users/someone/Documents/AcmeCorp-Secret-Project/abc-123.jsonl"
        let redacted = Diagnostics.redact(path: path)
        #expect(!redacted.contains("AcmeCorp"))
        #expect(!redacted.contains("someone"))
        #expect(!redacted.contains("abc-123"))
        #expect(!redacted.contains("/"))
        #expect(redacted.hasSuffix(".jsonl")) // extension is safe and useful
    }

    @Test func humanBytesScales() {
        #expect(Diagnostics.humanBytes(512) == "512 B")
        #expect(Diagnostics.humanBytes(2048).hasSuffix("KB"))
        #expect(Diagnostics.humanBytes(6_900_000).hasSuffix("MB"))
    }

    // MARK: - Watcher ancestor bounds

    @Test func ancestorSearchIsBoundedAndRefusesHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        // One level up from a missing leaf inside an existing dir: allowed.
        let inHomeDotDir = home + "/.tktracker-test-\(UUID().uuidString)/projects"
        // Its parent does not exist either, so two levels up lands on home,
        // which must be refused — subscribing to file events on the whole home
        // directory would wake the app on everything the user does.
        #expect(ProjectsWatcher.nearestExistingAncestor(of: inHomeDotDir) == nil)

        // A path directly under home: one level up IS home, so also refused.
        #expect(ProjectsWatcher.nearestExistingAncestor(of: home + "/.codex") == nil)

        // Deep enough that a real intermediate directory exists.
        let real = FileManager.default.temporaryDirectory
            .appendingPathComponent("tk-anc-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: real) }
        let missingLeaf = real.appendingPathComponent("sessions").path
        #expect(ProjectsWatcher.nearestExistingAncestor(of: missingLeaf) == ScanCore.canonicalPath(real))

        // Never walks past the configured bound.
        #expect(ProjectsWatcher.nearestExistingAncestor(of: "/a/b/c/d/e/f/g/h", maxLevels: 2) == nil)
    }

    @Test func watcherArmsOnAParentAndPromotesWhenTheTargetAppears() throws {
        // The fix for "FSEvents on a missing directory": a watcher must stand in
        // on a parent, and must become armed once the real directory shows up.
        // The store drives that retry on its minute tick, so what matters here is
        // that `isArmed` reflects reality and that `start()` is idempotent.
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("tk-watch-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let target = base.appendingPathComponent("sessions", isDirectory: true)
        #expect(!fm.fileExists(atPath: target.path))

        let watcher = ProjectsWatcher(path: target.path) {}
        defer { watcher.stop() }

        // Target absent, parent present: stands in on the parent rather than
        // creating a stream that can never fire.
        watcher.start()
        #expect(watcher.isArmed)

        // Idempotent — a retry on an armed watcher must not tear anything down.
        watcher.start()
        #expect(watcher.isArmed)

        watcher.stop()
        #expect(!watcher.isArmed)

        // Once the directory exists, arming targets it directly.
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        watcher.start()
        #expect(watcher.isArmed)
    }

    @Test func watcherStaysUnarmedRatherThanWatchingHome() throws {
        // Refusing is the point: arming FileEvents on the home directory would
        // wake the app on everything the user does.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let watcher = ProjectsWatcher(path: home + "/.tktracker-absent-\(UUID().uuidString)") {}
        defer { watcher.stop() }
        watcher.start()
        #expect(!watcher.isArmed, "must not fall back to the home directory")
    }

    // MARK: - Update URL trust

    @Test func onlyHttpsGitHubURLsAreTrusted() {
        // The release URL comes from a network response and is handed to
        // NSWorkspace.open on click.
        #expect(UpdateChecker.trustedReleaseURL("https://github.com/malclement/TkTracker/releases/tag/v1.6.0") != nil)
        #expect(UpdateChecker.trustedReleaseURL("https://api.github.com/whatever") != nil)

        #expect(UpdateChecker.trustedReleaseURL("file:///etc/passwd") == nil)
        #expect(UpdateChecker.trustedReleaseURL("http://github.com/x") == nil) // not https
        #expect(UpdateChecker.trustedReleaseURL("https://github.com.evil.tld/x") == nil)
        #expect(UpdateChecker.trustedReleaseURL("https://notgithub.com/x") == nil)
        #expect(UpdateChecker.trustedReleaseURL("javascript:alert(1)") == nil)
        #expect(UpdateChecker.trustedReleaseURL("") == nil)
        // Scheme comparison is case-insensitive.
        #expect(UpdateChecker.trustedReleaseURL("HTTPS://GitHub.com/x") != nil)
    }

    // MARK: - Session duration

    @Test func sessionDurationAndRateBoundaries() {
        func row(first: Double?, last: Double?, cost: Double) -> SessionRow {
            SessionRow(
                path: "/a.jsonl", sessionId: "s", source: .claude, title: "t",
                projectName: "p", cwd: nil, gitBranch: nil,
                firstActive: first.map { Date(timeIntervalSince1970: $0) },
                lastActive: last.map { Date(timeIntervalSince1970: $0) },
                model: "claude-opus-4-8", modelShortName: "Opus 4.8", family: .opus,
                totals: TokenTotals(), cost: cost, contextTokens: 0, contextLimit: 200_000,
                isLive: false, missing: false
            )
        }

        // Equal timestamps mean a single instant, not a zero-length session.
        #expect(row(first: 1000, last: 1000, cost: 5).duration == nil)
        #expect(row(first: nil, last: 1000, cost: 5).duration == nil)
        #expect(row(first: 1000, last: nil, cost: 5).duration == nil)
        // Clock skew must not produce a negative duration.
        #expect(row(first: 2000, last: 1000, cost: 5).duration == nil)

        let hour = row(first: 0, last: 3600, cost: 12)
        #expect(hour.duration == 3600)
        #expect(hour.costPerHour == 12)

        // Under a minute: the rate would be noise, so it is withheld.
        #expect(row(first: 0, last: 30, cost: 5).costPerHour == nil)
        #expect(row(first: 0, last: 60, cost: 5).costPerHour == 300)
    }
}
