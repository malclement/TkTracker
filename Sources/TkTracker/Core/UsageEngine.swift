import Foundation

/// Serialized owner of the digest set for the GUI app. Callers (the store) are
/// expected to funnel refreshes through a single loop; heavy parsing runs off
/// the actor on a detached task so the cooperative pool is never blocked.
actor UsageEngine {
    private let core: ScanCore
    private var digests: [String: FileDigest] = [:]
    private var claims: [String: String] = [:]
    private var dirty = false
    private var lastSave = Date.distantPast
    /// Bumped by reset(). A refresh whose detached scan started before a reset
    /// must drop its result, or it would resurrect the state the user purged.
    private var generation = 0

    init(core: ScanCore = ScanCore(root: ScanCore.defaultRoot(), cacheURL: ScanCore.defaultCacheURL())) {
        self.core = core
    }

    /// Load the persisted cache so the UI can render instantly before the first scan.
    func bootstrap() -> [FileDigest] {
        let cache = core.loadCache()
        digests = cache.digests
        claims = cache.claims
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

    func reset() async -> [FileDigest] {
        generation += 1
        core.clearCache()
        digests = [:]
        claims = [:]
        dirty = false
        return await refresh()
    }

    private func saveIfDue() {
        guard Date().timeIntervalSince(lastSave) > 15 else { return }
        flush()
    }
}
