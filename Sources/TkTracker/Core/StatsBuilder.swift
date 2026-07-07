import Foundation

enum StatsRange: String, CaseIterable, Identifiable, Codable, Sendable {
    case today, week, month, quarter, all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .today: return "Today"
        case .week: return "7D"
        case .month: return "30D"
        case .quarter: return "90D"
        case .all: return "All"
        }
    }

    func start(now: Date, calendar: Calendar) -> Date? {
        switch self {
        case .today: return calendar.startOfDay(for: now)
        case .week: return calendar.startOfDay(for: calendar.date(byAdding: .day, value: -6, to: now) ?? now)
        case .month: return calendar.startOfDay(for: calendar.date(byAdding: .day, value: -29, to: now) ?? now)
        case .quarter: return calendar.startOfDay(for: calendar.date(byAdding: .day, value: -89, to: now) ?? now)
        case .all: return nil
        }
    }
}

/// Granularity of the spend chart: hourly for Today, daily for short ranges,
/// weekly once the span would exceed ~4 months of daily bars.
enum ChartUnit: String, Codable, Sendable {
    case hour, day, week

    var seconds: TimeInterval {
        switch self {
        case .hour: return 3600
        case .day: return 86_400
        case .week: return 604_800
        }
    }
}

struct ChartPoint: Identifiable, Codable, Sendable {
    let date: Date
    let modelName: String // short display name, e.g. "Opus 4.6"
    let cost: Double
    let tokens: Int64
    var id: String { "\(date.timeIntervalSince1970)|\(modelName)" }
}

/// One entry per distinct model ever seen (all-time, not range-filtered), in stack
/// order: family, then version ascending. Color assignment derives from this, so
/// a model keeps its color no matter which range is selected.
struct ModelPaletteEntry: Codable, Sendable, Hashable {
    let name: String // short display name
    let family: ModelFamily
    let version: Double
}

struct HourPoint: Identifiable, Codable, Sendable {
    let date: Date
    let cost: Double
    let tokens: Int64
    var id: Date { date }
}

struct ModelRow: Identifiable, Codable, Sendable {
    let model: String
    let shortName: String
    let family: ModelFamily
    let totals: TokenTotals
    let cost: Double
    let share: Double
    let hasPricing: Bool
    var id: String { model }
}

struct ProjectRow: Identifiable, Codable, Sendable {
    let projectDir: String
    let name: String
    let path: String
    let sessions: Int
    let lastActive: Date?
    let totals: TokenTotals
    let cost: Double
    let share: Double
    var id: String { projectDir }
}

struct SessionRow: Identifiable, Codable, Sendable {
    let path: String
    let sessionId: String
    let title: String
    let projectName: String
    let cwd: String?
    let lastActive: Date?
    let model: String
    let modelShortName: String
    let family: ModelFamily
    let totals: TokenTotals
    let cost: Double
    let contextTokens: Int64
    let contextLimit: Int64
    let isLive: Bool
    let missing: Bool
    var id: String { path }
    var contextFraction: Double {
        contextLimit > 0 ? min(1, Double(contextTokens) / Double(contextLimit)) : 0
    }
}

struct BlockInfo: Codable, Sendable {
    let start: Date
    let end: Date
    let totals: TokenTotals
    let cost: Double
    let isActive: Bool
}

struct DashboardStats: Codable, Sendable {
    var range: StatsRange
    var generatedAt: Date
    var totals: TokenTotals
    var cost: Double
    var cacheSavings: Double
    var cacheHitRate: Double
    var activeSessions: Int
    var chart: [ChartPoint]
    var chartUnit: ChartUnit
    var modelPalette: [ModelPaletteEntry]
    var hourly24: [HourPoint]
    var models: [ModelRow]
    var projects: [ProjectRow]
    var sessions: [SessionRow]
    var liveSessions: [SessionRow]
    var block: BlockInfo?
    var todayCost: Double
    var todayTotals: TokenTotals
    var allTimeCost: Double
    var dataSince: Date?
    var hasEstimatedHistory: Bool
    /// Estimated spend per hour over the trailing hour (0 when idle).
    var burnRatePerHour: Double
    /// Today's cost vs yesterday at the same time of day, as a signed fraction.
    var todayVsYesterday: Double?

    static let empty = DashboardStats(
        range: .today, generatedAt: .distantPast, totals: TokenTotals(), cost: 0,
        cacheSavings: 0, cacheHitRate: 0, activeSessions: 0, chart: [], chartUnit: .hour,
        modelPalette: [], hourly24: [], models: [], projects: [], sessions: [], liveSessions: [],
        block: nil, todayCost: 0, todayTotals: TokenTotals(), allTimeCost: 0,
        dataSince: nil, hasEstimatedHistory: false,
        burnRatePerHour: 0, todayVsYesterday: nil
    )
}

enum StatsBuilder {
    static let blockLength: TimeInterval = 5 * 3600
    static let liveWindow: TimeInterval = 300

    static func build(
        digests: [FileDigest],
        range: StatsRange,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> DashboardStats {
        let nowEpoch = now.timeIntervalSince1970
        let rangeStart = range.start(now: now, calendar: calendar)?.timeIntervalSince1970
        let todayStart = calendar.startOfDay(for: now).timeIntervalSince1970

        let chartUnit: ChartUnit
        if range == .today {
            chartUnit = .hour
        } else {
            // Buckets are sorted per digest, so the first one is each file's earliest.
            let earliest = digests.compactMap { $0.buckets.first?.hour }.min().map(Double.init)
            let spanDays = (nowEpoch - (rangeStart ?? earliest ?? nowEpoch)) / 86_400
            chartUnit = spanDays > 120 ? .week : .day
        }

        struct HourAgg { var totals = TokenTotals(); var cost = 0.0 }
        struct ChartAgg { var cost = 0.0; var tokens: Int64 = 0 }
        struct ChartKey: Hashable { let date: Date; let modelName: String }
        struct ProjectAgg {
            var totals = TokenTotals()
            var cost = 0.0
            var sessions = 0
            var lastTs: Double?
            var cwd: String?
            var cwdTs: Double = -1
        }

        var rangeTotals = TokenTotals()
        var rangeCost = 0.0
        var savings = 0.0
        var byModel: [String: TokenTotals] = [:]
        var chartAgg: [ChartKey: ChartAgg] = [:]
        var hourAll: [Int64: HourAgg] = [:]
        var todayTotals = TokenTotals()
        var todayCost = 0.0
        var allTimeCost = 0.0
        var projectAgg: [String: ProjectAgg] = [:]
        var sessionRows: [SessionRow] = []
        var liveRows: [SessionRow] = []
        var activeSessions = 0
        var minHour: Int64?
        var hasEstimatedHistory = false
        var allModelIds: Set<String> = []
        var shortNameCache: [String: String] = [:]

        var bucketDateCache: [Int64: Date] = [:] // UTC hour -> local chart-bucket start

        for digest in digests {
            var inRange = TokenTotals()
            var inRangeCost = 0.0
            var todayDigestTotals = TokenTotals()
            var todayDigestCost = 0.0
            if digest.path == StatsCacheImport.syntheticPath { hasEstimatedHistory = true }

            for bucket in digest.buckets {
                let bucketCost = Pricing.cost(model: bucket.model, totals: bucket.totals)
                allTimeCost += bucketCost
                minHour = min(minHour ?? bucket.hour, bucket.hour)
                allModelIds.insert(bucket.model)

                var hourAgg = hourAll[bucket.hour] ?? HourAgg()
                hourAgg.totals.add(bucket.totals)
                hourAgg.cost += bucketCost
                hourAll[bucket.hour] = hourAgg

                if Double(bucket.hour) >= todayStart {
                    todayTotals.add(bucket.totals)
                    todayCost += bucketCost
                    todayDigestTotals.add(bucket.totals)
                    todayDigestCost += bucketCost
                }

                if let rangeStart, Double(bucket.hour) < rangeStart { continue }

                inRange.add(bucket.totals)
                inRangeCost += bucketCost
                rangeTotals.add(bucket.totals)
                rangeCost += bucketCost
                byModel[bucket.model, default: TokenTotals()].add(bucket.totals)
                savings += Pricing.cacheSavings(model: bucket.model, totals: bucket.totals)

                let bucketDate: Date
                if chartUnit == .hour {
                    bucketDate = Date(timeIntervalSince1970: Double(bucket.hour))
                } else if let cached = bucketDateCache[bucket.hour] {
                    bucketDate = cached
                } else {
                    let date = Date(timeIntervalSince1970: Double(bucket.hour))
                    let start: Date
                    switch chartUnit {
                    case .week:
                        start = calendar.dateInterval(of: .weekOfYear, for: date)?.start
                            ?? calendar.startOfDay(for: date)
                    default:
                        start = calendar.startOfDay(for: date)
                    }
                    bucketDateCache[bucket.hour] = start
                    bucketDate = start
                }
                let shortName: String
                if let cached = shortNameCache[bucket.model] {
                    shortName = cached
                } else {
                    shortName = ModelFamily.shortName(for: bucket.model)
                    shortNameCache[bucket.model] = shortName
                }
                let key = ChartKey(date: bucketDate, modelName: shortName)
                var agg = chartAgg[key] ?? ChartAgg()
                agg.cost += bucketCost
                agg.tokens = agg.tokens.saturatingAdding(bucket.totals.total)
                chartAgg[key] = agg
            }

            let isLive = !digest.missing && digest.lastTs.map { nowEpoch - $0 < liveWindow } ?? false
            if isLive { activeSessions += 1 }

            if inRange.messages > 0 || isLive {
                sessionRows.append(sessionRow(digest: digest, totals: inRange, cost: inRangeCost, isLive: isLive))

                var agg = projectAgg[digest.projectDir] ?? ProjectAgg()
                agg.totals.add(inRange)
                agg.cost += inRangeCost
                agg.sessions += 1
                if let last = digest.lastTs { agg.lastTs = max(agg.lastTs ?? last, last) }
                if let cwd = digest.cwd, (digest.lastTs ?? 0) > agg.cwdTs {
                    agg.cwd = cwd
                    agg.cwdTs = digest.lastTs ?? 0
                }
                projectAgg[digest.projectDir] = agg
            }

            if isLive {
                liveRows.append(sessionRow(digest: digest, totals: todayDigestTotals, cost: todayDigestCost, isLive: true))
            }
        }

        // All-time palette in stack order: family (validated adjacency), then version
        // ascending — so older generations sit below newer ones with receding steps.
        let familyIndex = Dictionary(uniqueKeysWithValues: ModelFamily.displayOrder.enumerated().map { ($1, $0) })
        var paletteByName: [String: ModelPaletteEntry] = [:]
        for id in allModelIds {
            let name = shortNameCache[id] ?? ModelFamily.shortName(for: id)
            if paletteByName[name] == nil {
                paletteByName[name] = ModelPaletteEntry(
                    name: name,
                    family: ModelFamily(model: id),
                    version: ModelFamily.version(of: id)
                )
            }
        }
        let modelPalette = paletteByName.values.sorted { a, b in
            let fa = familyIndex[a.family] ?? 9, fb = familyIndex[b.family] ?? 9
            if fa != fb { return fa < fb }
            if a.version != b.version { return a.version < b.version }
            return a.name < b.name
        }
        let paletteIndex = Dictionary(uniqueKeysWithValues: modelPalette.enumerated().map { ($1.name, $0) })

        let chart = chartAgg
            .map { ChartPoint(date: $0.key.date, modelName: $0.key.modelName, cost: $0.value.cost, tokens: $0.value.tokens) }
            .sorted {
                if $0.date != $1.date { return $0.date < $1.date }
                return (paletteIndex[$0.modelName] ?? 99) < (paletteIndex[$1.modelName] ?? 99)
            }

        let models = byModel
            .map { model, totals -> ModelRow in
                ModelRow(
                    model: model,
                    shortName: ModelFamily.shortName(for: model),
                    family: ModelFamily(model: model),
                    totals: totals,
                    cost: Pricing.cost(model: model, totals: totals),
                    share: 0,
                    hasPricing: Pricing.pricing(for: model) != nil
                )
            }
            .map { row in
                ModelRow(
                    model: row.model, shortName: row.shortName, family: row.family, totals: row.totals,
                    cost: row.cost, share: rangeCost > 0 ? row.cost / rangeCost : 0, hasPricing: row.hasPricing
                )
            }
            .sorted { $0.cost != $1.cost ? $0.cost > $1.cost : $0.totals.total > $1.totals.total }

        let projects = projectAgg
            .map { dir, agg -> ProjectRow in
                let (name, path) = Self.projectName(cwd: agg.cwd, projectDir: dir)
                return ProjectRow(
                    projectDir: dir,
                    name: name,
                    path: path,
                    sessions: agg.sessions,
                    lastActive: agg.lastTs.map { Date(timeIntervalSince1970: $0) },
                    totals: agg.totals,
                    cost: agg.cost,
                    share: rangeCost > 0 ? agg.cost / rangeCost : 0
                )
            }
            .sorted { $0.cost != $1.cost ? $0.cost > $1.cost : $0.totals.total > $1.totals.total }

        sessionRows.sort { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
        liveRows.sort { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }

        let promptTokens = rangeTotals.input
            .saturatingAdding(rangeTotals.cacheRead)
            .saturatingAdding(rangeTotals.cacheWrite)
        let hitRate = promptTokens > 0 ? Double(rangeTotals.cacheRead) / Double(promptTokens) : 0

        let nowHour = Int64(nowEpoch / 3600) * 3600
        let hourly24 = (0..<24).map { i -> HourPoint in
            let hour = nowHour - Int64(23 - i) * 3600
            let agg = hourAll[hour]
            return HourPoint(
                date: Date(timeIntervalSince1970: Double(hour)),
                cost: agg?.cost ?? 0,
                tokens: agg?.totals.total ?? 0
            )
        }

        // Trailing-hour spend: this hour so far plus the remainder-weighted previous hour.
        let elapsedInHour = nowEpoch - Double(nowHour)
        let burnRatePerHour = (hourAll[nowHour]?.cost ?? 0)
            + (hourAll[nowHour - 3600]?.cost ?? 0) * max(0, 3600 - elapsedInHour) / 3600

        // Yesterday's spend up to this time of day, boundary hour weighted by elapsed fraction.
        let todayStartDate = Date(timeIntervalSince1970: todayStart)
        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStartDate)?
            .timeIntervalSince1970 ?? (todayStart - 86_400)
        let sameTimeYesterday = yesterdayStart + (nowEpoch - todayStart)
        var yesterdayByNow = 0.0
        for (hour, agg) in hourAll {
            let h = Double(hour)
            guard h >= yesterdayStart, h < sameTimeYesterday, h < todayStart else { continue }
            let weight = h + 3600 <= sameTimeYesterday ? 1.0 : (sameTimeYesterday - h) / 3600
            yesterdayByNow += agg.cost * weight
        }
        let todayVsYesterday: Double? = yesterdayByNow > 0.01
            ? (todayCost - yesterdayByNow) / yesterdayByNow
            : nil

        return DashboardStats(
            range: range,
            generatedAt: now,
            totals: rangeTotals,
            cost: rangeCost,
            cacheSavings: savings,
            cacheHitRate: hitRate,
            activeSessions: activeSessions,
            chart: chart,
            chartUnit: chartUnit,
            modelPalette: modelPalette,
            hourly24: hourly24,
            models: models,
            projects: projects,
            sessions: sessionRows,
            liveSessions: Array(liveRows.prefix(4)),
            block: currentBlock(hourAll: hourAll.mapValues { ($0.totals, $0.cost) }, nowEpoch: nowEpoch),
            todayCost: todayCost,
            todayTotals: todayTotals,
            allTimeCost: allTimeCost,
            dataSince: minHour.map { Date(timeIntervalSince1970: Double($0)) },
            hasEstimatedHistory: hasEstimatedHistory,
            burnRatePerHour: burnRatePerHour,
            todayVsYesterday: todayVsYesterday
        )
    }

    private static func sessionRow(digest: FileDigest, totals: TokenTotals, cost: Double, isLive: Bool) -> SessionRow {
        let model = digest.lastModel ?? ""
        let (projectName, _) = projectName(cwd: digest.cwd, projectDir: digest.projectDir)
        return SessionRow(
            path: digest.path,
            sessionId: digest.sessionId,
            title: digest.title ?? "Untitled session",
            projectName: projectName,
            cwd: digest.cwd,
            lastActive: digest.lastTs.map { Date(timeIntervalSince1970: $0) },
            model: model,
            modelShortName: model.isEmpty ? "—" : ModelFamily.shortName(for: model),
            family: ModelFamily(model: model),
            totals: totals,
            cost: cost,
            contextTokens: digest.lastContextTokens,
            contextLimit: Pricing.contextWindow(for: model),
            isLive: isLive,
            missing: digest.missing
        )
    }

    /// Display name and path for a project. `cwd` (recorded in the session lines) is
    /// authoritative; the encoded folder name is a lossy fallback.
    static func projectName(cwd: String?, projectDir: String) -> (name: String, path: String) {
        if projectDir == StatsCacheImport.historyProjectDir {
            return ("Earlier history", "estimated from Claude Code's stats cache")
        }
        if let cwd, !cwd.isEmpty {
            let name = URL(fileURLWithPath: cwd).lastPathComponent
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let path = cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd
            return (name.isEmpty ? cwd : name, path)
        }
        let components = projectDir.split(separator: "-").map(String.init)
        let name = components.last ?? projectDir
        return (name, projectDir)
    }

    /// ccusage-compatible 5h billing blocks: a block opens at the first active hour,
    /// spans five hours, and the next activity past its end opens a new one.
    static func currentBlock(hourAll: [Int64: (TokenTotals, Double)], nowEpoch: Double) -> BlockInfo? {
        guard !hourAll.isEmpty else { return nil }
        let hours = hourAll.keys.sorted()
        var blockStart = hours[0]
        for hour in hours where hour >= blockStart + Int64(blockLength) {
            blockStart = hour
        }
        var totals = TokenTotals()
        var cost = 0.0
        for hour in hours where hour >= blockStart && hour < blockStart + Int64(blockLength) {
            if let agg = hourAll[hour] {
                totals.add(agg.0)
                cost += agg.1
            }
        }
        let start = Date(timeIntervalSince1970: Double(blockStart))
        let end = start.addingTimeInterval(blockLength)
        return BlockInfo(
            start: start,
            end: end,
            totals: totals,
            cost: cost,
            isActive: nowEpoch < end.timeIntervalSince1970
        )
    }
}
