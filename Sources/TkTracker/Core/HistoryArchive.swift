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
        var empty = DigestCache(version: Self.writeVersion, digests: [:], claims: ClaimMap())
        // No file yet is a legitimate fresh start, and writable.
        guard FileManager.default.fileExists(atPath: url.path) else { return empty }

        guard let data = try? Data(contentsOf: url) else {
            // A file we cannot even read might be a permissions problem that
            // resolves; do not clear the way to overwrite it.
            Diagnostics.scan.error("history archive unreadable: \(self.url.lastPathComponent, privacy: .public)")
            empty.isUnwritable = true
            return empty
        }

        guard var cache = try? JSONDecoder().decode(DigestCache.self, from: data) else {
            // Corrupt. Move it aside rather than overwrite it: a later build may
            // be able to salvage it, and the bytes are the only record of
            // sessions whose transcripts are gone. Quarantining lets the app
            // start a fresh archive without destroying evidence — but if the
            // rename fails, refuse to write instead.
            Diagnostics.scan.fault("history archive corrupt: \(self.url.lastPathComponent, privacy: .public)")
            empty.isUnwritable = !quarantine()
            return empty
        }

        // Reads anything from the floor up to the newest scan-cache version — a
        // v3 archive left by an interim build must still be understood — but
        // always normalizes back to the version this build writes.
        guard cache.version >= ScanCore.minimumCacheVersion, cache.version <= ScanCore.cacheVersion else {
            // From the future: the user has a newer build installed somewhere
            // and will go back to it. Leave the file exactly as it is.
            Diagnostics.scan.fault(
                "history archive version \(cache.version) is newer than this build understands — leaving it untouched"
            )
            empty.isUnwritable = true
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

    /// Renames an unparseable archive aside so a fresh one can be started
    /// without destroying the old bytes. Returns whether the file is now clear.
    private func quarantine() -> Bool {
        let stamp = Int(Date().timeIntervalSince1970)
        let aside = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).unreadable-\(stamp)")
        do {
            try FileManager.default.moveItem(at: url, to: aside)
            Diagnostics.scan.notice("moved unreadable archive aside as \(aside.lastPathComponent, privacy: .public)")
            return true
        } catch {
            Diagnostics.scan.fault(
                "could not quarantine unreadable archive: \(error.localizedDescription, privacy: .public) — refusing to overwrite it"
            )
            return false
        }
    }

    @discardableResult
    func save(_ cache: DigestCache) -> Bool {
        // Refuse to write over a file this build declined to read. See
        // `DigestCache.isUnwritable`.
        guard !cache.isUnwritable else {
            Diagnostics.scan.error("refusing to overwrite history archive that could not be read")
            return false
        }
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
        // An archive this build declined to read must not be rebuilt from
        // partial state — returning nil keeps the caller from even attempting a
        // save, which would otherwise log a refusal on every refresh.
        guard !archive.isUnwritable else { return nil }

        var out = archive
        var changed = false
        // Owners whose archived digest changed this pass. Harvesting on *any*
        // change, not only a fresh insert, matters: an already-archived digest
        // that gains buckets (file reappeared, was re-parsed, pruned again)
        // brings claims of its own, and skipping those would reopen double
        // counting after a reset. In the steady state nothing changes, so this
        // stays empty and the 20k+ claim table is not walked at all.
        var touched: Set<String> = []
        for (path, digest) in digests where digest.missing {
            guard out.digests[path] != digest else { continue }
            out.digests[path] = digest
            touched.insert(path)
            changed = true
        }

        if !touched.isEmpty {
            for entry in claims.entries(ownedByAnyOf: touched) where out.claims[entry.key] == nil {
                out.claims.set(entry.key, owner: entry.owner)
                changed = true
            }
            Diagnostics.scan.notice(
                "archived \(touched.count) pruned session(s); archive now holds \(out.digests.count) digests, \(out.claims.count) claims"
            )
        }
        return changed ? out : nil
    }
}
