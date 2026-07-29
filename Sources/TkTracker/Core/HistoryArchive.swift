import Foundation

/// Durable record of exact usage for transcripts Claude Code has pruned.
///
/// The scan cache already keeps digests of deleted session files, but it is
/// disposable by design: "Rescan everything" clears it, and a cache-version
/// bump discards it. Without a backstop, either event silently downgrades the
/// pruned period from exact transcript data to the stats-cache *estimate*.
///
/// The archive is that backstop. Whenever a refresh marks a digest missing
/// (file pruned), its exact buckets — and the claim-table entries its messages
/// own — are copied here and never removed. Bootstrap and reset seed the scan
/// state from it, so from the moment TkTracker first observes a session, its
/// precise values outlive the transcript, the scan cache, and any reset; the
/// estimated "Earlier history" stays clipped to days before first app use.
struct HistoryArchive: Sendable {
    /// The archive deliberately stays on the v2 on-disk shape while scan caches
    /// moved to v3.
    ///
    /// An older TkTracker that meets a format it cannot parse *discards* the
    /// file. For a scan cache that is harmless — it is re-derived from the
    /// transcripts on disk. For the archive it is permanent: these digests
    /// describe sessions whose transcripts no longer exist anywhere. Since the
    /// archive is also the smaller and far less frequently written of the two,
    /// forgoing the interning win here is cheap insurance against a downgrade,
    /// a parallel install, or an older build still running.
    static let writeVersion = 2

    var source: UsageSource = .claude
    let url: URL

    /// Lives next to the scan cache and is namespaced per data root the same
    /// way, so alternating `CLAUDE_CONFIG_DIR` profiles keep separate archives.
    static func defaultURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        if environment["CLAUDE_CONFIG_DIR"]?.isEmpty == false {
            let suffix = ScanCore.stableHash(ScanCore.defaultRoot(environment: environment).path)
            return base.appendingPathComponent("TkTracker/history-archive-\(suffix).json")
        }
        return base.appendingPathComponent("TkTracker/history-archive.json")
    }

    /// Per-source archives mirror the per-source scan caches: the Claude file
    /// keeps its historical name; Codex gets its own (namespaced per
    /// `CODEX_HOME` root the same way).
    static func defaultURL(
        for source: UsageSource,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        switch source {
        case .claude:
            return defaultURL(environment: environment)
        case .codex:
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            if environment["CODEX_HOME"]?.isEmpty == false {
                let suffix = ScanCore.stableHash(ScanCore.defaultRoot(for: .codex, environment: environment).path)
                return base.appendingPathComponent("TkTracker/history-archive-codex-\(suffix).json")
            }
            return base.appendingPathComponent("TkTracker/history-archive-codex.json")
        }
    }

    /// Version handling here is deliberately forgiving in one direction only: an
    /// older format is migrated (see `DigestCache.init(from:)`), because these
    /// digests can never be re-derived — the transcripts they describe are gone.
    /// Discarding them on a format bump would silently downgrade real spend to
    /// the stats-cache estimate, which is exactly what this file exists to
    /// prevent. A *newer* format (downgraded app) is left alone rather than
    /// half-read.
    func load() -> DigestCache {
        let empty = DigestCache(version: Self.writeVersion, digests: [:], claims: ClaimMap())
        guard FileManager.default.fileExists(atPath: url.path) else { return empty }
        guard let data = try? Data(contentsOf: url) else {
            Diagnostics.scan.error("history archive unreadable: \(self.url.lastPathComponent, privacy: .public)")
            return empty
        }
        guard var cache = try? JSONDecoder().decode(DigestCache.self, from: data) else {
            Diagnostics.scan.fault("history archive corrupt: \(self.url.lastPathComponent, privacy: .public) — exact history for pruned sessions is lost")
            return empty
        }
        // Reads anything from the floor up to the newest scan-cache version —
        // a v3 archive left by an interim build must still be understood — but
        // always normalizes back to the version this build writes.
        guard cache.version >= ScanCore.minimumCacheVersion, cache.version <= ScanCore.cacheVersion else {
            Diagnostics.scan.fault("history archive version \(cache.version) unsupported — refusing to read")
            return empty
        }
        if cache.version != Self.writeVersion {
            Diagnostics.scan.notice("normalizing history archive v\(cache.version) -> v\(Self.writeVersion)")
            cache.version = Self.writeVersion
            cache.wasMigrated = true
        }
        // `source` isn't persisted — the per-source archive file implies it.
        if source != .claude {
            for (path, var digest) in cache.digests {
                digest.source = source
                cache.digests[path] = digest
            }
        }
        return cache
    }

    @discardableResult
    func save(_ cache: DigestCache) -> Bool {
        do {
            let data = try JSONEncoder().encode(cache)
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            Diagnostics.scan.fault(
                "history archive save failed: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    /// Restore archived sessions into scan state before a scan. Live entries
    /// win — a digest present in the scan cache (or a file back on disk) is
    /// fresher than its archived copy, and existing claims keep their owners.
    /// Seeded claims stop a post-reset rescan from re-claiming (and so
    /// double-counting) messages that archived sessions already counted.
    static func seed(
        archive: DigestCache,
        intoDigests digests: inout [String: FileDigest],
        claims: inout ClaimMap
    ) {
        for (path, digest) in archive.digests where digests[path] == nil {
            digests[path] = digest
        }
        claims.seed(from: archive.claims)
    }

    /// Fold freshly missing digests (and the claims their messages own) into
    /// the archive. Returns nil when nothing changed so callers skip the write;
    /// in the steady state files rarely vanish, so saves are rare too.
    static func updated(
        _ archive: DigestCache,
        digests: [String: FileDigest],
        claims: ClaimMap
    ) -> DigestCache? {
        var out = archive
        var changed = false
        var newlyArchived: Set<String> = []
        for (path, digest) in digests where digest.missing {
            guard out.digests[path] != digest else { continue }
            if out.digests[path] == nil { newlyArchived.insert(path) }
            out.digests[path] = digest
            changed = true
        }

        // Only a session that just entered the archive can contribute claims —
        // one already here brought its own in the pass that archived it, and the
        // two are saved together. Gating on that keeps a 20k+ entry claim table
        // out of the steady-state refresh path, which runs every few hundred
        // milliseconds while a session streams.
        if !newlyArchived.isEmpty {
            for entry in claims.entries(ownedByAnyOf: newlyArchived) where out.claims[entry.key] == nil {
                out.claims.set(entry.key, owner: entry.owner)
                changed = true
            }
            Diagnostics.scan.notice(
                "archived \(newlyArchived.count) pruned session(s); archive now holds \(out.digests.count) digests, \(out.claims.count) claims"
            )
        }
        return changed ? out : nil
    }
}
