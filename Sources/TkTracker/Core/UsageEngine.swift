import Foundation

/// Serialized owner of the digest set for the GUI app. Callers (the store) are
/// expected to funnel refreshes through a single loop; heavy parsing runs off
/// the actor on a detached task so the cooperative pool is never blocked.
actor UsageEngine {
    private let core: ScanCore
    private let archive: HistoryArchive
    private var archiveCache = DigestCache(version: ScanCore.cacheVersion, digests: [:], claims: [:])
    private var digests: [String: FileDigest] = [:]
    private var claims: [String: String] = [:]
    private var dirty = false
    private var lastSave = Date.distantPast
    /// Bumped by reset(). A refresh whose detached scan started before a reset
    /// must drop its result, or it would resurrect the state the user purged.
    private var generation = 0

    init(
        core: ScanCore = ScanCore(root: ScanCore.defaultRoot(), cacheURL: ScanCore.defaultCacheURL()),
        archive: HistoryArchive = HistoryArchive(url: HistoryArchive.defaultURL())
    ) {
        self.core = core
        self.archive = archive
    }

    /// Load the persisted cache so the UI can render instantly before the first scan.
    func bootstrap() -> [FileDigest] {
        let cache = core.loadCache()
        archiveCache = archive.load()
        digests = cache.digests
        claims = cache.claims
        HistoryArchive.seed(archive: archiveCache, intoDigests: &digests, claims: &claims)
        return Array(digests.values)
    }

    func refresh() async -> [FileDigest] {
        let digestsSnapshot = digests
        let claimsSnapshot = claims
        let startGeneration = generation
        let core = self.core
        let result = await Task.detached(priority: .userInitiated) {
            core.refreshed(digests: digestsSnapshot, claims: claimsSnapshot)
        }.value
        guard startGeneration == generation else { return Array(digests.values) }
        digests = result.digests
        claims = result.claims
        if let updated = HistoryArchive.updated(archiveCache, digests: digests, claims: claims) {
            archiveCache = updated
            archive.save(updated)
        }
        if result.changed {
            dirty = true
            saveIfDue()
        }
        return Array(digests.values)
    }

    func flush() {
        guard dirty else { return }
        core.saveCache(digests: digests, claims: claims)
        dirty = false
        lastSave = Date()
    }

    /// Clears the scan cache and re-parses everything on disk. The history
    /// archive is deliberately kept: pruned transcripts can never be re-read,
    /// so dropping their archived digests would downgrade those days to the
    /// stats-cache estimate.
    func reset() async -> [FileDigest] {
        generation += 1
        core.clearCache()
        digests = [:]
        claims = [:]
        HistoryArchive.seed(archive: archiveCache, intoDigests: &digests, claims: &claims)
        dirty = false
        return await refresh()
    }

    private func saveIfDue() {
        guard Date().timeIntervalSince(lastSave) > 15 else { return }
        flush()
    }
}
