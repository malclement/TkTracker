import Foundation

struct PrivacyPolicy: Codable, Equatable, Sendable {
    var omitTitles = false
    /// Keeps token, cost and branch accounting forever; expires only detail metadata.
    var detailRetentionDays = 0
    static func load() -> Self {
        if PricingCatalog.isRunningTests { return Self() }
        let d = UserDefaults(suiteName: "com.clementmalige.tktracker") ?? .standard
        return d.data(forKey: "privacyPolicy").flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
    }
    func apply(_ digest: FileDigest, now: Date = Date()) -> FileDigest {
        var d = digest
        let expired = detailRetentionDays > 0 && (d.lastTs ?? 0) < now.timeIntervalSince1970 - Double(detailRetentionDays) * 86400
        if omitTitles || expired { d.aiTitle = nil; d.fallbackTitle = nil }
        if expired {
            d.markers = nil
            d.records = d.records?.map { var b = $0; b.contextTokens = nil; return b }
        }
        return d
    }
}

/// Usage metadata only: never transcripts, credentials, or arbitrary file copies.
struct ArchiveBackup: Codable, Sendable {
    var version = 1
    var createdAt = Date()
    var entries: [Entry]
    struct Entry: Codable, Sendable {
        var profileId: String
        var source: UsageSource
        var rootPath: String
        var cache: DigestCache
    }
    enum Failure: LocalizedError {
        case unsupported, invalid, unknownProfile(String), persistence
        var errorDescription: String? {
            switch self {
            case .unsupported: return "This backup uses an unsupported version."
            case .invalid: return "The backup is invalid or larger than 256 MB."
            case .unknownProfile(let name): return "Configure the original account folder before restoring profile \(name)."
            case .persistence: return "Could not save archive changes. Existing history was retained; check disk space and permissions."
            }
        }
    }
    static func read(_ url: URL) throws -> Self {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 256 << 20 else { throw Failure.invalid }
        let backup = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard backup.version == 1 else { throw Failure.unsupported }
        guard Set(backup.entries.map(\.profileId)).count == backup.entries.count,
              backup.entries.allSatisfy({ entry in
                  (ScanCore.minimumCacheVersion...ScanCore.cacheVersion).contains(entry.cache.version)
                  && entry.cache.digests.allSatisfy { $0.key == $0.value.path }
              }) else { throw Failure.invalid }
        return backup
    }
    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
