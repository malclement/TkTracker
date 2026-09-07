import Foundation

struct SourceProfile: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var name: String
    var source: UsageSource
    var rootPath: String
    var enabled: Bool = true
    var plan: UsagePlan = .none

    var root: URL { URL(fileURLWithPath: (rootPath as NSString).expandingTildeInPath).standardizedFileURL }
    var pipeline: (core: ScanCore, archive: HistoryArchive) {
        let standard = ScanCore.defaultRoot(for: source)
        let cache: URL
        let archive: URL
        if ScanCore.canonicalPath(root) == ScanCore.canonicalPath(standard) {
            cache = ScanCore.defaultCacheURL(for: source)
            archive = HistoryArchive.defaultURL(for: source)
        } else {
            let base = ScanCore.defaultCacheURL(for: source).deletingLastPathComponent()
            let suffix = source.rawValue + "-" + ScanCore.stableHash(ScanCore.canonicalPath(root))
            cache = base.appendingPathComponent("scan-cache-\(suffix).json")
            archive = base.appendingPathComponent("history-archive-\(suffix).json")
        }
        return (ScanCore(source: source, root: root, cacheURL: cache, profileId: id), HistoryArchive(source: source, url: archive))
    }

    static func load(from defaults: UserDefaults = UserDefaults(suiteName: "com.clementmalige.tktracker") ?? .standard) -> [SourceProfile] {
        if let data = defaults.data(forKey: "sourceProfiles"),
           let profiles = try? JSONDecoder().decode([SourceProfile].self, from: data), !profiles.isEmpty {
            return unique(profiles)
        }
        let old = UsagePlan.load(from: defaults)
        return UsageSource.allCases.map { source in
            let ownsOldPlan = old.id.hasPrefix("chatgpt") ? source == .codex : source == .claude
            return SourceProfile(id: source.rawValue, name: source.displayName, source: source,
                rootPath: ScanCore.defaultRoot(for: source).path, plan: ownsOldPlan ? old : .none)
        }
    }

    /// A directory cannot be scanned twice under two account labels.
    static func unique(_ profiles: [SourceProfile]) -> [SourceProfile] {
        var seen = Set<String>()
        var ids = Set<String>()
        return profiles.filter { profile in
            guard !profile.rootPath.isEmpty, ids.insert(profile.id).inserted else { return false }
            let key = profile.source.rawValue + "|" + ScanCore.canonicalPath(profile.root)
            guard !seen.contains(where: { $0 == key || $0.hasPrefix(key + "/") || key.hasPrefix($0 + "/") }) else { return false }
            seen.insert(key)
            return true
        }
    }

    static func save(_ profiles: [SourceProfile], to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(unique(profiles)) { defaults.set(data, forKey: "sourceProfiles") }
    }
}

struct AccountUsage: Codable, Sendable, Identifiable {
    var id: String
    var name: String
    var source: UsageSource
    var monthlyPayment: Double
    var rollingValue: Double
    var block: PlanGauge?
    var weekly: PlanGauge?
    var valueMultiple: Double? { monthlyPayment > 0 ? rollingValue / monthlyPayment : nil }

    static func build(profiles: [SourceProfile], digests: [FileDigest], now: Date = Date()) -> [AccountUsage] {
        profiles.filter(\.enabled).map { profile in
            let chosen = digests.filter { ($0.profileId ?? $0.source.rawValue) == profile.id }
            var hours: [Int64: (TokenTotals, Double)] = [:]
            var week = 0.0, month = 0.0
            for digest in chosen {
                for b in digest.accountingBuckets where b.epoch <= now.timeIntervalSince1970 {
                    let cost = b.cost
                    if b.epoch >= now.timeIntervalSince1970 - 30 * 86400 { month += cost }
                    if b.epoch >= now.timeIntervalSince1970 - 7 * 86400 { week += cost }
                    var h = hours[b.hour] ?? (TokenTotals(), 0)
                    h.0.add(b.totals); h.1 += cost; hours[b.hour] = h
                }
            }
            let current = StatsBuilder.currentBlock(hourAll: hours, nowEpoch: now.timeIntervalSince1970)
            return AccountUsage(id: profile.id, name: profile.name, source: profile.source,
                monthlyPayment: profile.plan.monthlyCost, rollingValue: month,
                block: profile.plan.tracksBlock ? current.map { PlanGauge(used: $0.cost, limit: profile.plan.blockLimit, windowEnd: $0.end) } : nil,
                weekly: profile.plan.tracksWeekly ? PlanGauge(used: week, limit: profile.plan.weeklyLimit, windowEnd: nil) : nil)
        }
    }
}
