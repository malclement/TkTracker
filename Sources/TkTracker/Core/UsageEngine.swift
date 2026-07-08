import Foundation

/// Serialized owner of the digest sets for the GUI app — one scan pipeline per
/// usage source, merged for the store. Callers (the store) are expected to
/// funnel refreshes through a single loop; heavy parsing runs off the actor on
/// a detached task so the cooperative pool is never blocked.
actor UsageEngine {
    private struct SourceState {
        let core: ScanCore
        let archive: HistoryArchive
        var archiveCache = DigestCache(version: ScanCore.cacheVersion, digests: [:], claims: [:])
        var digests: [String: FileDigest] = [:]
        var claims: [String: String] = [:]
        var dirty = false
    }

    private var states: [UsageSource: SourceState]
    private let order: [UsageSource]
    private var lastSave = Date.distantPast
    /// Bumped by reset(). A refresh whose detached scan started before a reset
    /// must drop its result, or it would resurrect the state the user purged.
    private var generation = 0

    init(pipelines: [(core: ScanCore, archive: HistoryArchive)] = UsageEngine.defaultPipelines()) {
        var states: [UsageSource: SourceState] = [:]
        var order: [UsageSource] = []
        for pipeline in pipelines {
            states[pipeline.core.source] = SourceState(core: pipeline.core, archive: pipeline.archive)
            order.append(pipeline.core.source)
        }
        self.states = states
        self.order = order
    }

    static func defaultPipelines() -> [(core: ScanCore, archive: HistoryArchive)] {
        UsageSource.allCases.map { source in
            (
                core: ScanCore(
                    source: source,
                    root: ScanCore.defaultRoot(for: source),
                    cacheURL: ScanCore.defaultCacheURL(for: source)
                ),
                archive: HistoryArchive(source: source, url: HistoryArchive.defaultURL(for: source))
            )
        }
    }

    /// Load the persisted caches so the UI can render instantly before the first scan.
    func bootstrap() -> [FileDigest] {
        for source in order {
            guard var state = states[source] else { continue }
            let cache = state.core.loadCache()
            state.archiveCache = state.archive.load()
            state.digests = cache.digests
            state.claims = cache.claims
            HistoryArchive.seed(archive: state.archiveCache, intoDigests: &state.digests, claims: &state.claims)
            states[source] = state
        }
        return allDigests()
    }

    func refresh(sources: Set<UsageSource>) async -> [FileDigest] {
        for source in order where sources.contains(source) {
            guard let state = states[source] else { continue }
            let digestsSnapshot = state.digests
            let claimsSnapshot = state.claims
            let startGeneration = generation
            let core = state.core
            let result = await Task.detached(priority: .userInitiated) {
                core.refreshed(digests: digestsSnapshot, claims: claimsSnapshot)
            }.value
            guard startGeneration == generation, var updated = states[source] else { continue }
            updated.digests = result.digests
            updated.claims = result.claims
            if let archived = HistoryArchive.updated(updated.archiveCache, digests: result.digests, claims: result.claims) {
                updated.archiveCache = archived
                updated.archive.save(archived)
            }
            if result.changed { updated.dirty = true }
            states[source] = updated
        }
        saveIfDue()
        return allDigests()
    }

    func flush() {
        for source in order {
            guard var state = states[source], state.dirty else { continue }
            state.core.saveCache(digests: state.digests, claims: state.claims)
            state.dirty = false
            states[source] = state
        }
        lastSave = Date()
    }

    /// Clears every source's scan cache — "Rescan everything" is the clean-slate
    /// action, so even a currently untracked source's cache is purged (it gets
    /// re-derived from disk when re-enabled) — then re-parses the given sources.
    /// The history archives are deliberately kept: pruned session files can
    /// never be re-read, so dropping their archived digests would downgrade
    /// those days to the stats-cache estimate (or lose them outright for Codex).
    func reset(rescanning sources: Set<UsageSource>) async -> [FileDigest] {
        generation += 1
        for source in order {
            guard var state = states[source] else { continue }
            state.core.clearCache()
            state.digests = [:]
            state.claims = [:]
            HistoryArchive.seed(archive: state.archiveCache, intoDigests: &state.digests, claims: &state.claims)
            state.dirty = false
            states[source] = state
        }
        return await refresh(sources: sources)
    }

    private func allDigests() -> [FileDigest] {
        order.flatMap { states[$0].map { Array($0.digests.values) } ?? [] }
    }

    private func saveIfDue() {
        guard states.values.contains(where: \.dirty) else { return }
        guard Date().timeIntervalSince(lastSave) > 15 else { return }
        flush()
    }
}
