import Foundation

/// Thread-safe ownership registry for usage events. The first file to claim a
/// (messageId:requestId) key owns it; copies of the same event in other files
/// (session resumes, forks) are skipped so spend is never double-counted.
final class ClaimTable: @unchecked Sendable {
    private var claims: [String: String]
    private let lock = NSLock()

    init(claims: [String: String] = [:]) {
        self.claims = claims
    }

    /// True if `owner` may count this event (fresh claim, or re-parse by the owner).
    func claim(_ key: String, owner: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let existing = claims[key] { return existing == owner }
        claims[key] = owner
        return true
    }

    var snapshot: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return claims
    }
}

/// Synchronous scanning primitives shared by the app engine and the CLI:
/// file discovery, change detection, parallel incremental parsing, cache IO.
/// One instance per usage source — same machinery, different root, parser and
/// cache file.
struct ScanCore: Sendable {
    static let cacheVersion = 2

    var source: UsageSource = .claude
    let root: URL
    let cacheURL: URL

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

    func listFiles() -> [FileMeta] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        let rootPath = root.path
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
        var claims: [String: String]
        var changed: Bool
    }

    /// Stat every session file, re-parse only what changed. Pure with respect to
    /// the inputs; returns the updated digests, claim table and a change flag.
    func refreshed(digests: [String: FileDigest], claims: [String: String]) -> RefreshResult {
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

        // Oldest-first biases the cold-scan claim race toward original sessions.
        // Exactly-once counting never depends on order — only display attribution
        // does, and claims persist, so attribution is stable after the first scan.
        let work = files
            .filter { meta in
                guard let d = result[meta.url.path] else { return true }
                return d.missing || d.size != meta.size || abs(d.mtime - meta.mtime) > 0.0005
            }
            .sorted { $0.mtime < $1.mtime }
        guard !work.isEmpty else {
            return RefreshResult(digests: result, claims: claims, changed: changed)
        }

        let source = self.source
        let claimTable = ClaimTable(claims: claims)
        var scanned = [FileDigest?](repeating: nil, count: work.count)
        scanned.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations: work.count) { i in
                let meta = work[i]
                switch source {
                case .claude:
                    base[i] = JSONLParser.scan(
                        url: meta.url,
                        previous: digests[meta.url.path],
                        projectDir: meta.projectDir,
                        size: meta.size,
                        mtime: meta.mtime,
                        claims: claimTable
                    )
                case .codex:
                    base[i] = CodexParser.scan(
                        url: meta.url,
                        previous: digests[meta.url.path],
                        size: meta.size,
                        mtime: meta.mtime
                    )
                }
            }
        }
        for digest in scanned {
            guard let digest else { continue }
            result[digest.path] = digest
            changed = true
        }
        return RefreshResult(digests: result, claims: claimTable.snapshot, changed: true)
    }

    // MARK: - Cache

    func loadCache() -> DigestCache {
        guard let data = try? Data(contentsOf: cacheURL),
              var cache = try? JSONDecoder().decode(DigestCache.self, from: data),
              cache.version == Self.cacheVersion
        else { return DigestCache(version: Self.cacheVersion, digests: [:], claims: [:]) }
        // `source` isn't persisted — the per-source cache file implies it.
        if source != .claude {
            for (path, var digest) in cache.digests {
                digest.source = source
                cache.digests[path] = digest
            }
        }
        return cache
    }

    func saveCache(digests: [String: FileDigest], claims: [String: String]) {
        let cache = DigestCache(version: Self.cacheVersion, digests: digests, claims: claims)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        let dir = cacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    func clearCache() {
        try? FileManager.default.removeItem(at: cacheURL)
    }
}
