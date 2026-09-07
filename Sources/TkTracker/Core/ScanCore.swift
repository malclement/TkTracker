import Foundation

/// Synchronous scanning primitives shared by the app engine and the CLI:
/// file discovery, change detection, parallel incremental parsing, cache IO.
/// One instance per usage source — same machinery, different root, parser and
/// cache file.
struct ScanCore: Sendable {
    /// Bumped to 3 in 1.5.0 when claim-table owner paths were interned. Older
    /// caches are migrated on read (see `DigestCache.init(from:)`), never dropped.
    static let cacheVersion = 3
    /// Oldest on-disk format still understood. A cache below this, or above
    /// `cacheVersion` (a downgrade), is discarded rather than misread.
    static let minimumCacheVersion = 2

    var source: UsageSource = .claude
    let root: URL
    let cacheURL: URL
    var profileId: String?

    /// Claude Code's data directory: `CLAUDE_CONFIG_DIR` if set, else `~/.claude`.
    /// Everything that locates Claude Code data (transcripts, stats cache) must
    /// resolve through here so a custom profile is honored consistently.
    static func configRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let custom = environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
    }

    /// Codex CLI's data directory: `CODEX_HOME` if set, else `~/.codex`.
    static func codexConfigRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let custom = environment["CODEX_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }

    static func defaultRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        configRoot(environment: environment).appendingPathComponent("projects", isDirectory: true)
    }

    static func defaultRoot(
        for source: UsageSource,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        switch source {
        case .claude:
            return defaultRoot(environment: environment)
        case .codex:
            return codexConfigRoot(environment: environment)
                .appendingPathComponent("sessions", isDirectory: true)
        }
    }

    /// The scan cache is namespaced per data root: the default root keeps the
    /// historical file name, a `CLAUDE_CONFIG_DIR` override gets its own cache so
    /// alternating profiles never merge each other's digests into one history.
    static func defaultCacheURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        if environment["CLAUDE_CONFIG_DIR"]?.isEmpty == false {
            let suffix = stableHash(defaultRoot(environment: environment).path)
            return base.appendingPathComponent("TkTracker/scan-cache-\(suffix).json")
        }
        return base.appendingPathComponent("TkTracker/scan-cache.json")
    }

    /// Codex digests live in their own cache file (`CODEX_HOME` overrides are
    /// namespaced like Claude profiles); the Claude cache keeps its pre-source
    /// name and format, so up/downgrading the app never mixes the two.
    static func defaultCacheURL(
        for source: UsageSource,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        switch source {
        case .claude:
            return defaultCacheURL(environment: environment)
        case .codex:
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            if environment["CODEX_HOME"]?.isEmpty == false {
                let suffix = stableHash(defaultRoot(for: .codex, environment: environment).path)
                return base.appendingPathComponent("TkTracker/scan-cache-codex-\(suffix).json")
            }
            return base.appendingPathComponent("TkTracker/scan-cache-codex.json")
        }
    }

    /// FNV-1a — deterministic across launches, unlike `Hasher`.
    static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    struct FileMeta: Sendable {
        let url: URL
        let projectDir: String
        let size: Int64
        let mtime: Double
    }

    /// Fully resolved filesystem path, following symlinks.
    ///
    /// The enumerator hands back canonical paths, so a root that reaches the
    /// same directory through a symlink (`/var/...` vs `/private/var/...`, or a
    /// symlinked `CLAUDE_CONFIG_DIR`) would fail the prefix check below and make
    /// every project name the first component of the *absolute* path. That
    /// produced silently wrong project grouping rather than an error, so both
    /// sides are canonicalized before comparing.
    static func canonicalPath(_ url: URL) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(url.path, &buffer) != nil else { return url.path }
        return String(cString: buffer)
    }

    func listFiles() -> [FileMeta] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        let rootPath = Self.canonicalPath(root)
        var out: [FileMeta] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let rv = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                  rv.isRegularFile == true else { continue }
            // Claude nests sessions under an encoded-project folder; Codex nests
            // by date (YYYY/MM/DD), so its project comes from the file's cwd.
            var projectDir = ""
            if source == .claude {
                var rel = url.path
                if rel.hasPrefix(rootPath) { rel = String(rel.dropFirst(rootPath.count)) }
                projectDir = rel.split(separator: "/").first.map(String.init) ?? ""
            }
            out.append(FileMeta(
                url: url,
                projectDir: projectDir,
                size: Int64(rv.fileSize ?? 0),
                mtime: rv.contentModificationDate?.timeIntervalSince1970 ?? 0
            ))
        }
        return out
    }

    struct RefreshResult: Sendable {
        var digests: [String: FileDigest]
        var claims: ClaimMap
        var changed: Bool
        /// Files that could not be read this pass. Surfaced rather than swallowed,
        /// so a permissions problem shows up as a warning instead of quietly
        /// lower numbers.
        var unreadable: [String] = []
    }

    /// Stat every session file, re-parse only what changed. Pure with respect to
    /// the inputs; returns the updated digests, claim table and a change flag.
    func refreshed(digests: [String: FileDigest], claims: ClaimMap) -> RefreshResult {
        let files = listFiles()
        var result = digests
        var changed = false

        let presentPaths = Set(files.map(\.url.path))
        for (path, digest) in result where !presentPaths.contains(path) && !digest.missing {
            var d = digest
            d.missing = true // file deleted (e.g. Claude Code cleanup) — keep history
            result[path] = d
            changed = true
        }

        // Repair project attribution on digests that will not be re-parsed.
        //
        // `projectDir` is computed during discovery but only stored when a file is
        // actually parsed, and the change-detection filter below skips anything
        // whose size and mtime are unchanged. So the symlinked-root fix would
        // otherwise never reach an existing install: every already-scanned session
        // would keep its wrong project name until the file happened to grow, which
        // for a completed session is never.
        if source == .claude {
            for meta in files {
                guard var digest = result[meta.url.path],
                      digest.projectDir != meta.projectDir,
                      !meta.projectDir.isEmpty
                else { continue }
                Diagnostics.scan.notice("repaired project attribution for a cached session")
                digest.projectDir = meta.projectDir
                result[meta.url.path] = digest
                changed = true
            }
        }

        // Oldest-first biases the cold-scan claim race toward original sessions.
        // Exactly-once counting never depends on order — only display attribution
        // does, and claims persist, so attribution is stable after the first scan.
        let work = files
            .filter { meta in
                guard let d = result[meta.url.path] else { return true }
                return d.parserRevision != 2 || d.missing || d.size != meta.size || abs(d.mtime - meta.mtime) > 0.0005
            }
            .sorted { $0.mtime < $1.mtime }

        // A changed file we cannot open would otherwise vanish into the parsers'
        // `try?` and show up only as quietly lower numbers. Check once, up front,
        // and keep the last known digest for anything unreadable.
        let fm = FileManager.default
        var unreadable: [String] = []
        let readable = work.filter { meta in
            guard fm.isReadableFile(atPath: meta.url.path) else {
                unreadable.append(meta.url.path)
                return false
            }
            return true
        }

        if !unreadable.isEmpty {
            Diagnostics.scan.error("\(unreadable.count) session file(s) unreadable; keeping last known digests")
        }

        guard !readable.isEmpty else {
            return RefreshResult(digests: result, claims: claims, changed: changed, unreadable: unreadable)
        }

        let source = self.source
        let claimTable = ClaimTable(claims)
        var scanned = [FileDigest?](repeating: nil, count: readable.count)
        scanned.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            let workers = min(4, readable.count)
            DispatchQueue.concurrentPerform(iterations: workers) { worker in
                for i in stride(from: worker, to: readable.count, by: workers) {
                    let meta = readable[i]
                    base[i] = source.adapter.scan(meta, previous: digests[meta.url.path], claims: claimTable)
                }
            }
        }
        for digest in scanned {
            guard var digest else { continue }
            digest.profileId = profileId ?? source.rawValue
            digest = PrivacyPolicy.load().apply(digest)
            result[digest.path] = digest
            changed = true
        }
        return RefreshResult(
            digests: result,
            claims: claimTable.snapshot,
            changed: true,
            unreadable: unreadable
        )
    }

    // MARK: - Cache

    func loadCache() -> DigestCache {
        let empty = DigestCache(version: Self.cacheVersion, digests: [:], claims: ClaimMap())
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { return empty }
        guard let data = try? Data(contentsOf: cacheURL) else {
            Diagnostics.scan.error("cache unreadable at \(self.cacheURL.lastPathComponent, privacy: .public)")
            return empty
        }
        guard var cache = try? JSONDecoder().decode(DigestCache.self, from: data) else {
            Diagnostics.scan.error("cache corrupt at \(self.cacheURL.lastPathComponent, privacy: .public); rebuilding")
            return empty
        }
        // Below the floor is unreadable; above it is a downgrade from a future
        // build. Anything in between migrated on decode and is rewritten in the
        // current shape on the next save.
        guard cache.version >= Self.minimumCacheVersion, cache.version <= Self.cacheVersion else {
            Diagnostics.scan.notice("cache version \(cache.version) unsupported; rebuilding")
            return empty
        }
        if cache.version != Self.cacheVersion {
            Diagnostics.scan.notice(
                "migrated cache v\(cache.version) -> v\(Self.cacheVersion), \(cache.claims.count) claims"
            )
            cache.version = Self.cacheVersion
            cache.wasMigrated = true
        }
        // `source` isn't persisted — the per-source cache file implies it.
        if source != .claude {
            for (path, var digest) in cache.digests {
                digest.source = source
                cache.digests[path] = digest
            }
        }
        return cache
    }

    @discardableResult
    func saveCache(digests: [String: FileDigest], claims: ClaimMap) -> Bool {
        let cache = DigestCache(version: Self.cacheVersion, digests: digests, claims: claims)
        do {
            let data = try JSONEncoder().encode(cache)
            let dir = cacheURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: cacheURL, options: .atomic)
            return true
        } catch {
            Diagnostics.scan.error(
                "cache save failed for \(self.cacheURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    func clearCache() {
        try? FileManager.default.removeItem(at: cacheURL)
    }
}
