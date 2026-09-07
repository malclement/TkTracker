import Foundation

/// Serialized owner of the digest sets for the GUI app — one scan pipeline per
/// usage source, merged for the store. Callers (the store) are expected to
/// funnel refreshes through a single loop; heavy parsing runs off the actor on
/// a detached task so the cooperative pool is never blocked.
actor UsageEngine {
    private struct SourceState {
        let core: ScanCore
        let archive: HistoryArchive
        var archiveCache = DigestCache(version: HistoryArchive.writeVersion, digests: [:], claims: ClaimMap())
        var digests: [String: FileDigest] = [:]
        var claims = ClaimMap()
        var dirty = false
    }

    /// What a refresh observed, beyond the digests themselves.
    struct RefreshReport: Sendable {
        var digests: [FileDigest] = []
        var unreadable: [String] = []
        var cacheWriteFailed = false
        var duration: TimeInterval = 0
        var claimCount = 0
    }

    private var states: [String: SourceState]
    private var order: [String]
    private var lastSave = Date.distantPast

    /// Test seam: awaited once, after a detached scan returns but before its
    /// result is applied.
    ///
    /// The generation guard below only matters when a reset lands while a scan is
    /// in flight, and that interleaving cannot be produced reliably by racing two
    /// calls — so without a seam the test for it passed whether or not the guard
    /// existed. One-shot, so the reset performed inside the hook does not re-enter
    /// it. Nil in every non-test path.
    private var scanInterleaveHook: (@Sendable () async -> Void)?

    func setScanInterleaveHook(_ hook: (@Sendable () async -> Void)?) {
        scanInterleaveHook = hook
    }
    /// Bumped by reset(). A refresh whose detached scan started before a reset
    /// must drop its result, or it would resurrect the state the user purged.
    private var generation = 0

    init(pipelines: [(core: ScanCore, archive: HistoryArchive)] = UsageEngine.defaultPipelines()) {
        var states: [String: SourceState] = [:]
        var order: [String] = []
        for pipeline in pipelines {
            let id = pipeline.core.profileId ?? pipeline.core.source.rawValue
            states[id] = SourceState(core: pipeline.core, archive: pipeline.archive)
            order.append(id)
        }
        self.states = states
        self.order = order
    }

    static func defaultPipelines() -> [(core: ScanCore, archive: HistoryArchive)] {
        SourceProfile.load().filter(\.enabled).map(\.pipeline)
    }

    func configure(profiles: [SourceProfile]) -> RefreshReport {
        guard flush() else { var report = snapshot(); report.cacheWriteFailed = true; return report }
        generation += 1
        states = [:]
        order = []
        for profile in SourceProfile.unique(profiles) where profile.enabled {
            let pipeline = profile.pipeline
            states[profile.id] = SourceState(core: pipeline.core, archive: pipeline.archive)
            order.append(profile.id)
        }
        return bootstrap()
    }

    /// Load the persisted caches so the UI can render instantly before the first scan.
    ///
    /// Everything is assembled in locals and written back to `state` in one go.
    /// Passing `&state.digests` and `&state.claims` inout while also reading
    /// `state.archiveCache` in the same call is an overlapping access to `state`
    /// that trips Swift's exclusivity checker at runtime.
    func bootstrap() -> RefreshReport {
        for source in order {
            guard var state = states[source] else { continue }
            let cache = state.core.loadCache()
            let archiveCache = state.archive.load()

            var digests = cache.digests
            var claims = cache.claims
            HistoryArchive.seed(archive: archiveCache, intoDigests: &digests, claims: &claims)

            // The archive has no dirty flag — it is only written when a session
            // is pruned, which may not happen for weeks. Persist a migration
            // right away so it converts once rather than on every launch.
            if archiveCache.wasMigrated {
                state.archive.save(archiveCache)
            }

            state.archiveCache = archiveCache
            for path in digests.keys { digests[path]?.profileId = source }
            state.digests = digests.mapValues { PrivacyPolicy.load().apply($0) }
            state.claims = claims
            // A cache read at an older version was migrated in memory; mark it
            // dirty so the upgraded shape reaches disk on the next save rather
            // than being re-migrated on every launch.
            if cache.wasMigrated { state.dirty = true }
            states[source] = state

            Diagnostics.scan.info(
                "\(source, privacy: .public) bootstrap: \(digests.count) digests, \(claims.count) claims"
            )
        }
        return snapshot()
    }

    func refresh(sources: Set<UsageSource>) async -> RefreshReport {
        let started = Date()
        var report = RefreshReport()
        for source in order where states[source].map({ sources.contains($0.core.source) }) == true {
            guard let state = states[source] else { continue }
            let digestsSnapshot = state.digests
            let claimsSnapshot = state.claims
            let startGeneration = generation
            let core = state.core
            let result = await Task.detached(priority: .userInitiated) {
                core.refreshed(digests: digestsSnapshot, claims: claimsSnapshot)
            }.value
            if let hook = scanInterleaveHook {
                scanInterleaveHook = nil
                await hook()
            }
            guard startGeneration == generation, var updated = states[source] else {
                Diagnostics.scan.notice("dropped stale \(source) scan result after reset")
                continue
            }
            updated.digests = result.digests.mapValues { PrivacyPolicy.load().apply($0) }
            updated.claims = result.claims
            report.unreadable.append(contentsOf: result.unreadable)
            if let archived = HistoryArchive.updated(updated.archiveCache, digests: updated.digests, claims: result.claims) {
                updated.archiveCache = archived
                if !updated.archive.save(archived) { report.cacheWriteFailed = true }
            }
            if result.changed { updated.dirty = true }
            states[source] = updated
        }
        if !saveIfDue() { report.cacheWriteFailed = true }
        report.digests = allDigests()
        report.claimCount = states.values.reduce(0) { $0 + $1.claims.count }
        report.duration = Date().timeIntervalSince(started)
        return report
    }

    /// Returns false if any dirty cache failed to persist.
    @discardableResult
    func flush() -> Bool {
        var ok = true
        for source in order {
            guard var state = states[source], state.dirty else { continue }
            if state.core.saveCache(digests: state.digests, claims: state.claims) {
                state.dirty = false
            } else {
                ok = false
            }
            states[source] = state
        }
        lastSave = Date()
        return ok
    }

    /// Clears every source's scan cache — "Rescan everything" is the clean-slate
    /// action, so even a currently untracked source's cache is purged (it gets
    /// re-derived from disk when re-enabled) — then re-parses the given sources.
    /// The history archives are deliberately kept: pruned session files can
    /// never be re-read, so dropping their archived digests would downgrade
    /// those days to the stats-cache estimate (or lose them outright for Codex).
    func reset(rescanning sources: Set<UsageSource>) async -> RefreshReport {
        generation += 1
        Diagnostics.scan.notice("rescan everything: clearing scan caches, keeping history archives")
        for source in order {
            guard var state = states[source] else { continue }
            state.core.clearCache()
            // Locals for the same exclusivity reason as `bootstrap`.
            var digests: [String: FileDigest] = [:]
            var claims = ClaimMap()
            HistoryArchive.seed(archive: state.archiveCache, intoDigests: &digests, claims: &claims)
            state.digests = digests.mapValues { PrivacyPolicy.load().apply($0) }
            state.claims = claims
            state.dirty = false
            states[source] = state
        }
        return await refresh(sources: sources)
    }

    func backup() -> ArchiveBackup {
        ArchiveBackup(entries: order.compactMap { id in
            guard let state = states[id] else { return nil }
            let policy = PrivacyPolicy.load()
            let cache = DigestCache(version: HistoryArchive.writeVersion,
                digests: state.digests.mapValues { policy.apply($0) }, claims: state.claims)
            return ArchiveBackup.Entry(profileId: id, source: state.core.source,
                rootPath: ScanCore.canonicalPath(state.core.root), cache: cache)
        })
    }

    /// Merge missing entries only. Existing session data and claim owners win.
    /// All entries are validated before any archive is changed.
    func restore(_ backup: ArchiveBackup) throws -> RefreshReport {
        var proposed = states
        for entry in backup.entries {
            guard var state = proposed[entry.profileId], state.core.source == entry.source,
                  ScanCore.canonicalPath(state.core.root) == entry.rootPath else {
                throw ArchiveBackup.Failure.unknownProfile(entry.profileId)
            }
            guard !state.archiveCache.isUnwritable else { throw ArchiveBackup.Failure.persistence }
            var imported = entry.cache
            for (path, var digest) in imported.digests {
                digest.source = state.core.source
                digest.profileId = entry.profileId
                digest.missing = true
                imported.digests[path] = PrivacyPolicy.load().apply(digest)
            }
            HistoryArchive.seed(archive: imported, intoDigests: &state.digests, claims: &state.claims)
            // A restored live session also needs a durable copy before rescanning.
            HistoryArchive.seed(archive: imported, intoDigests: &state.archiveCache.digests, claims: &state.archiveCache.claims)
            state.dirty = true
            proposed[entry.profileId] = state
        }
        var saved: [String] = []
        for id in order {
            guard let state = proposed[id] else { continue }
            guard state.archive.save(state.archiveCache) else {
                for prior in saved { if let old = states[prior] { old.archive.save(old.archiveCache) } }
                throw ArchiveBackup.Failure.persistence
            }
            saved.append(id)
        }
        generation += 1
        states = proposed
        guard flush() else { throw ArchiveBackup.Failure.persistence }
        return snapshot()
    }

    func applyPrivacy(_ policy: PrivacyPolicy) throws -> RefreshReport {
        generation += 1
        for id in order {
            guard var state = states[id] else { continue }
            state.digests = state.digests.mapValues { policy.apply($0) }
            state.archiveCache.digests = state.archiveCache.digests.mapValues { policy.apply($0) }
            state.dirty = true
            states[id] = state
            guard state.archive.save(state.archiveCache) else { throw ArchiveBackup.Failure.persistence }
        }
        guard flush() else { throw ArchiveBackup.Failure.persistence }
        return snapshot()
    }

    /// Digest snapshot without a rescan — used at launch, and whenever the store
    /// needs the current set after a settings change.
    func snapshot() -> RefreshReport {
        var report = RefreshReport()
        report.digests = allDigests()
        report.claimCount = states.values.reduce(0) { $0 + $1.claims.count }
        return report
    }

    private func allDigests() -> [FileDigest] {
        order.flatMap { states[$0].map { Array($0.digests.values) } ?? [] }
    }

    @discardableResult
    private func saveIfDue() -> Bool {
        guard states.values.contains(where: \.dirty) else { return true }
        guard Date().timeIntervalSince(lastSave) > 15 else { return true }
        return flush()
    }
}
