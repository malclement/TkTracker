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

    func load() -> DigestCache {
        guard let data = try? Data(contentsOf: url),
              var cache = try? JSONDecoder().decode(DigestCache.self, from: data),
              cache.version == ScanCore.cacheVersion
        else { return DigestCache(version: ScanCore.cacheVersion, digests: [:], claims: [:]) }
        // `source` isn't persisted — the per-source archive file implies it.
        if source != .claude {
            for (path, var digest) in cache.digests {
                digest.source = source
                cache.digests[path] = digest
            }
        }
        return cache
    }

    func save(_ cache: DigestCache) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Restore archived sessions into scan state before a scan. Live entries
    /// win — a digest present in the scan cache (or a file back on disk) is
    /// fresher than its archived copy, and existing claims keep their owners.
    /// Seeded claims stop a post-reset rescan from re-claiming (and so
    /// double-counting) messages that archived sessions already counted.
    static func seed(
        archive: DigestCache,
        intoDigests digests: inout [String: FileDigest],
        claims: inout [String: String]
    ) {
        for (path, digest) in archive.digests where digests[path] == nil {
            digests[path] = digest
        }
        for (key, owner) in archive.claims where claims[key] == nil {
            claims[key] = owner
        }
    }

    /// Fold freshly missing digests (and the claims their messages own) into
    /// the archive. Returns nil when nothing changed so callers skip the write;
    /// in the steady state files rarely vanish, so saves are rare too.
    static func updated(
        _ archive: DigestCache,
        digests: [String: FileDigest],
        claims: [String: String]
    ) -> DigestCache? {
        var out = archive
        var changed = false
        for (path, digest) in digests where digest.missing {
            if out.digests[path] != digest {
                out.digests[path] = digest
                changed = true
            }
        }
        for (key, owner) in claims where out.claims[key] == nil && out.digests[owner] != nil {
            out.claims[key] = owner
            changed = true
        }
        return changed ? out : nil
    }
}
