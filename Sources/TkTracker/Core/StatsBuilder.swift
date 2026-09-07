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
    let source: UsageSource
    let title: String
    let projectName: String
    let cwd: String?
    let gitBranch: String?
    let firstActive: Date?
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

    /// Wall-clock span from the session's first usage event to its last. This is
    /// elapsed time, not billed time — a session left open over lunch counts the
    /// lunch — so it is only shown alongside cost, never instead of it.
    var duration: TimeInterval? {
        guard let firstActive, let lastActive, lastActive > firstActive else { return nil }
        return lastActive.timeIntervalSince(firstActive)
    }

    /// Spend per hour of elapsed session time. nil for sessions too short to be
    /// meaningful (under a minute), where the figure would be pure noise.
    var costPerHour: Double? {
        guard let duration, duration >= 60 else { return nil }
        return cost / (duration / 3600)
    }
}

/// Usage attributed to one git branch within a project. Branch names are already
/// recorded in both transcript formats; this surfaces them.
struct BranchRow: Identifiable, Codable, Sendable {
    let branch: String
    let projectName: String
    let sessions: Int
    let totals: TokenTotals
    let cost: Double
    let lastActive: Date?
    var projectId: String?
    var id: String { "\(projectId ?? projectName)\u{1F}\(branch)" }
}

/// One weekday × hour-of-day cell of the activity heatmap.
struct HeatCell: Identifiable, Codable, Sendable {
    /// 1 = Sunday, matching `Calendar.component(.weekday:)`.
    let weekday: Int
    /// 0–23, local time.
    let hour: Int
    let cost: Double
    let tokens: Int64
    var id: Int { weekday * 100 + hour }
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
    /// Rolling 7-day and 30-day spend, independent of the selected range — plan
    /// allowances and the value multiple are about real windows, not the view.
    var rollingWeekCost: Double
    var rollingMonthCost: Double
    /// Plan allowance consumption, nil when no plan is configured.
    var blockGauge: PlanGauge?
    var weeklyGauge: PlanGauge?
    /// Trailing-30-day API-equivalent value divided by the plan's monthly cost.
    var planValueMultiple: Double?
    /// Today's projected end-of-day total, from how far through a typical day
    /// this time of day usually is. nil when there isn't enough history.
    var projectedTodayCost: Double?
    /// Weekday × hour-of-day activity over the selected range.
    var heatmap: [HeatCell]
    /// Per-git-branch attribution over the selected range.
    var branches: [BranchRow]
    /// Range cost/tokens split by usage source (raw values), for the source breakdown.
    var costBySource: [String: Double]
    var totalsBySource: [String: TokenTotals]
    /// Today's cost split by usage source.
    var todayCostBySource: [String: Double]

    var coverage = PricingCoverage()
    var previousPeriodCost: Double?
    var accounts: [AccountUsage] = []

    func cost(for source: UsageSource) -> Double { costBySource[source.rawValue] ?? 0 }
    func totals(for source: UsageSource) -> TokenTotals { totalsBySource[source.rawValue] ?? TokenTotals() }
    func todayCost(for source: UsageSource) -> Double { todayCostBySource[source.rawValue] ?? 0 }

    /// The single JSON encoding of a stats document.
    ///
    /// The GUI export and `report --json` are documented as interchangeable, and
    /// were not: they configured their own encoders and had already drifted
    /// (`withoutEscapingSlashes` on one side only). One implementation, so the
    /// claim stays true.
    func jsonDocument() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    static let empty = DashboardStats(
        range: .today, generatedAt: .distantPast, totals: TokenTotals(), cost: 0,
        cacheSavings: 0, cacheHitRate: 0, activeSessions: 0, chart: [], chartUnit: .hour,
        modelPalette: [], hourly24: [], models: [], projects: [], sessions: [], liveSessions: [],
        block: nil, todayCost: 0, todayTotals: TokenTotals(), allTimeCost: 0,
        dataSince: nil, hasEstimatedHistory: false,
        burnRatePerHour: 0, todayVsYesterday: nil,
        rollingWeekCost: 0, rollingMonthCost: 0,
        blockGauge: nil, weeklyGauge: nil, planValueMultiple: nil, projectedTodayCost: nil,
        heatmap: [], branches: [],
        costBySource: [:], totalsBySource: [:], todayCostBySource: [:]
    )
}

enum StatsBuilder {
    static let blockLength: TimeInterval = 5 * 3600
    static let liveWindow: TimeInterval = 300

    static func build(
        digests: [FileDigest],
        range: StatsRange,
        now: Date = Date(),
        calendar: Calendar = .current,
        plan: UsagePlan = .none,
        filter: ReportFilter? = nil,
        profiles: [SourceProfile] = []
    ) -> DashboardStats {
        let digests = filter?.apply(to: digests) ?? digests
        let nowEpoch = now.timeIntervalSince1970
        let interval = filter?.interval(now: now, calendar: calendar)
        let rangeStart = interval?.start.timeIntervalSince1970 ?? range.start(now: now, calendar: calendar)?.timeIntervalSince1970
        let rangeEnd = min(interval?.end.timeIntervalSince1970 ?? nowEpoch + 1, nowEpoch + 1)
        let previousStart = rangeStart.map { $0 - (rangeEnd - $0) }
        var previousCost = 0.0
        var coverage = PricingCoverage(catalogUpdated: PricingCatalog.shared.updated)
        var unpricedModels = Set<String>()
        var byModelCost: [String: Double] = [:]
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
        struct BranchKey: Hashable { let project: String; let branch: String; let name: String }
        struct BranchAgg {
            var totals = TokenTotals()
            var cost = 0.0
            var sessions = 0
            var lastTs: Double?
        }
        struct HeatKey: Hashable { let weekday: Int; let hour: Int }
        struct HeatAgg { var cost = 0.0; var tokens: Int64 = 0 }

        var rangeTotals = TokenTotals()
        var rangeCost = 0.0
        var savings = 0.0
        var byModel: [String: TokenTotals] = [:]
        var chartAgg: [ChartKey: ChartAgg] = [:]
        var hourAll: [Int64: HourAgg] = [:]
        var todayTotals = TokenTotals()
        var todayCost = 0.0
        var costBySource: [String: Double] = [:]
        var totalsBySource: [String: TokenTotals] = [:]
        var todayCostBySource: [String: Double] = [:]
        var allTimeCost = 0.0
        var projectAgg: [String: ProjectAgg] = [:]
        var sessionRows: [SessionRow] = []
        var liveRows: [SessionRow] = []
        var activeSessions = 0
        var minHour: Int64?
        var hasEstimatedHistory = false
        var allModelIds: Set<String> = []
        var shortNameCache: [String: String] = [:]
        var branchAgg: [BranchKey: BranchAgg] = [:]
        var heatAgg: [HeatKey: HeatAgg] = [:]

        var bucketDateCache: [Int64: Date] = [:] // UTC hour -> local chart-bucket start
        var heatKeyCache: [Int64: HeatKey] = [:] // UTC hour -> local (weekday, hour)

        // Rolling windows for plan allowances and the value multiple. These are
        // deliberately independent of the selected range: an allowance is about
        // a real window of time, not about what the user is currently looking at.
        let weekStart = nowEpoch - 7 * 86_400
        let monthStart = nowEpoch - 30 * 86_400
        var rollingWeekCost = 0.0
        var rollingMonthCost = 0.0

        for digest in digests {
            var inRange = TokenTotals()
            var inRangeCost = 0.0
            var todayDigestTotals = TokenTotals()
            var todayDigestCost = 0.0
            if digest.path.hasPrefix(StatsCacheImport.syntheticPath) { hasEstimatedHistory = true }

            var seenBranches = Set<String>()
            for bucket in digest.accountingBuckets {
                guard bucket.epoch <= nowEpoch + 1 else { continue }
                let bucketCost = bucket.cost
                allTimeCost += bucketCost
                minHour = min(minHour ?? bucket.hour, bucket.hour)
                allModelIds.insert(bucket.model)

                var hourAgg = hourAll[bucket.hour] ?? HourAgg()
                hourAgg.totals.add(bucket.totals)
                hourAgg.cost += bucketCost
                hourAll[bucket.hour] = hourAgg

                if bucket.epoch >= weekStart { rollingWeekCost += bucketCost }
                if bucket.epoch >= monthStart { rollingMonthCost += bucketCost }

                if bucket.epoch >= todayStart {
                    todayTotals.add(bucket.totals)
                    todayCost += bucketCost
                    todayDigestTotals.add(bucket.totals)
                    todayDigestCost += bucketCost
                }

                if let rangeStart, let previousStart, bucket.epoch >= previousStart, bucket.epoch < rangeStart { previousCost += bucketCost }
                if let rangeStart, bucket.epoch < rangeStart { continue }
                if bucket.epoch >= rangeEnd { continue }
                if PricingCatalog.shared.pricing(for: bucket.model, context: bucket.context) == nil {
                    coverage.unpricedTokens = coverage.unpricedTokens.saturatingAdding(bucket.totals.total)
                    coverage.unpricedRequests = coverage.unpricedRequests.saturatingAdding(bucket.totals.messages)
                    unpricedModels.insert(bucket.model)
                }
                if bucket.context?.tier == .unknown || bucket.context == nil {
                    coverage.assumedTierRequests = coverage.assumedTierRequests.saturatingAdding(bucket.totals.messages)
                }
                if bucket.timestamp == nil { coverage.legacyRequests = coverage.legacyRequests.saturatingAdding(bucket.totals.messages) }
                if digest.path.hasPrefix(StatsCacheImport.syntheticPath) { coverage.estimatedTokens = coverage.estimatedTokens.saturatingAdding(bucket.totals.total) }
                byModelCost[bucket.model, default: 0] += bucketCost
                if let branch = bucket.branch ?? (digest.records == nil ? digest.gitBranch : nil), !branch.isEmpty {
                    let name = Self.projectName(cwd: digest.cwd, projectDir: digest.projectDir).name
                    let key = BranchKey(project: digest.projectKey, branch: branch, name: name)
                    var b = branchAgg[key] ?? BranchAgg()
                    b.totals.add(bucket.totals)
                    b.cost += bucketCost
                    if seenBranches.insert(branch).inserted { b.sessions += 1 }
                    b.lastTs = max(b.lastTs ?? bucket.epoch, bucket.epoch)
                    branchAgg[key] = b
                }

                inRange.add(bucket.totals)
                inRangeCost += bucketCost
                rangeTotals.add(bucket.totals)
                rangeCost += bucketCost
                byModel[bucket.model, default: TokenTotals()].add(bucket.totals)
                savings += Pricing.cacheSavings(model: bucket.model, totals: bucket.totals, context: bucket.context)

                let bucketDate: Date
                if chartUnit == .hour {
                    bucketDate = calendar.dateInterval(of: .hour, for: Date(timeIntervalSince1970: bucket.epoch))!.start
                } else if let cached = bucketDateCache[Int64(bucket.epoch / 60)] {
                    bucketDate = cached
                } else {
                    let date = Date(timeIntervalSince1970: bucket.epoch)
                    let start: Date
                    switch chartUnit {
                    case .week:
                        start = calendar.dateInterval(of: .weekOfYear, for: date)?.start
                            ?? calendar.startOfDay(for: date)
                    default:
                        start = calendar.startOfDay(for: date)
                    }
                    bucketDateCache[Int64(bucket.epoch / 60)] = start
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

                // Heatmap cells are local weekday × local hour, so the grid reads
                // as "when do I actually work" rather than as UTC.
                let heatKey: HeatKey
                if let cached = heatKeyCache[Int64(bucket.epoch / 60)] {
                    heatKey = cached
                } else {
                    let date = Date(timeIntervalSince1970: bucket.epoch)
                    let parts = calendar.dateComponents([.weekday, .hour], from: date)
                    heatKey = HeatKey(weekday: parts.weekday ?? 1, hour: parts.hour ?? 0)
                    heatKeyCache[Int64(bucket.epoch / 60)] = heatKey
                }
                var heat = heatAgg[heatKey] ?? HeatAgg()
                heat.cost += bucketCost
                heat.tokens = heat.tokens.saturatingAdding(bucket.totals.total)
                heatAgg[heatKey] = heat
            }

            if inRangeCost > 0 { costBySource[digest.source.rawValue, default: 0] += inRangeCost }
            if !inRange.isEmpty { totalsBySource[digest.source.rawValue, default: TokenTotals()].add(inRange) }
            if todayDigestCost > 0 { todayCostBySource[digest.source.rawValue, default: 0] += todayDigestCost }

            let isLive = !digest.missing && digest.lastTs.map { nowEpoch - $0 < liveWindow } ?? false
            if isLive { activeSessions += 1 }

            if inRange.messages > 0 || isLive {
                sessionRows.append(sessionRow(digest: digest, totals: inRange, cost: inRangeCost, isLive: isLive))

                var agg = projectAgg[digest.projectKey] ?? ProjectAgg()
                agg.totals.add(inRange)
                agg.cost += inRangeCost
                agg.sessions += 1
                if let last = digest.lastTs { agg.lastTs = max(agg.lastTs ?? last, last) }
                if let cwd = digest.cwd, (digest.lastTs ?? 0) > agg.cwdTs {
                    agg.cwd = cwd
                    agg.cwdTs = digest.lastTs ?? 0
                }
                projectAgg[digest.projectKey] = agg


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
                    cost: byModelCost[model] ?? 0,
                    share: 0,
                    hasPricing: !unpricedModels.contains(model)
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

        let block = currentBlock(hourAll: hourAll.mapValues { ($0.totals, $0.cost) }, nowEpoch: nowEpoch)

        // Plan allowances. Both are nil unless the user configured a limit — the
        // app never invents a threshold it wasn't given.
        let blockGauge: PlanGauge? = plan.tracksBlock && block != nil
            ? PlanGauge(used: block!.cost, limit: plan.blockLimit, windowEnd: block!.end)
            : nil
        let weeklyGauge: PlanGauge? = plan.tracksWeekly
            ? PlanGauge(
                used: rollingWeekCost,
                limit: plan.weeklyLimit,
                windowEnd: nil
            )
            : nil
        let planValueMultiple: Double? = plan.tracksValue && plan.monthlyCost > 0
            ? rollingMonthCost / plan.monthlyCost
            : nil

        let heatmap = heatAgg
            .map { HeatCell(weekday: $0.key.weekday, hour: $0.key.hour, cost: $0.value.cost, tokens: $0.value.tokens) }
            .sorted { ($0.weekday, $0.hour) < ($1.weekday, $1.hour) }

        let branches = branchAgg
            .map { key, agg in
                BranchRow(
                    branch: key.branch,
                    projectName: key.name,
                    sessions: agg.sessions,
                    totals: agg.totals,
                    cost: agg.cost,
                    lastActive: agg.lastTs.map { Date(timeIntervalSince1970: $0) },
                    projectId: key.project
                )
            }
            .sorted { $0.cost != $1.cost ? $0.cost > $1.cost : $0.totals.total > $1.totals.total }

        var result = DashboardStats(
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
            block: block,
            todayCost: todayCost,
            todayTotals: todayTotals,
            allTimeCost: allTimeCost,
            dataSince: minHour.map { Date(timeIntervalSince1970: Double($0)) },
            hasEstimatedHistory: hasEstimatedHistory,
            burnRatePerHour: burnRatePerHour,
            todayVsYesterday: todayVsYesterday,
            rollingWeekCost: rollingWeekCost,
            rollingMonthCost: rollingMonthCost,
            blockGauge: blockGauge,
            weeklyGauge: weeklyGauge,
            planValueMultiple: planValueMultiple,
            projectedTodayCost: projectedToday(
                hourAll: hourAll.mapValues(\.cost),
                todayCost: todayCost,
                todayStart: todayStart,
                nowEpoch: nowEpoch,
                calendar: calendar
            ),
            heatmap: heatmap,
            branches: branches,
            costBySource: costBySource,
            totalsBySource: totalsBySource,
            todayCostBySource: todayCostBySource
        )
        result.accounts = AccountUsage.build(profiles: profiles, digests: digests, now: now)
        result.coverage = coverage
        result.previousPeriodCost = rangeStart == nil ? nil : previousCost
        return result
    }

    /// Today's projected end-of-day total.
    ///
    /// Extrapolating the trailing burn rate to midnight assumes you keep working
    /// all night, which is wrong most evenings and badly wrong at 09:05. Instead
    /// this asks the data a narrower question: on past days, what share of the
    /// day's spend had landed by this hour? The median of that share over recent
    /// active days divides today's spend so far.
    ///
    /// Returns nil when there aren't enough comparable days, or when the share is
    /// too small to divide by — an honest "not enough history" beats a confident
    /// wrong number.
    static func projectedToday(
        hourAll: [Int64: Double],
        todayCost: Double,
        todayStart: Double,
        nowEpoch: Double,
        calendar: Calendar,
        lookbackDays: Int = 21,
        minimumDays: Int = 5
    ) -> Double? {
        guard todayCost > 0.01 else { return nil }
        let elapsed = nowEpoch - todayStart
        guard elapsed > 1800 else { return nil } // too early to say anything

        // Day windows, oldest first. Built once so the hour scan below can locate
        // an hour's day by binary search instead of rescanning all of history
        // per lookback day — that was 21 × |hourAll|, and |hourAll| grows with
        // every hour ever recorded.
        struct Day { let start: Double; let end: Double; let sameTime: Double }
        let todayStartDate = Date(timeIntervalSince1970: todayStart)
        var days: [Day] = []
        for dayOffset in stride(from: lookbackDays, through: 1, by: -1) {
            guard let dayStartDate = calendar.date(byAdding: .day, value: -dayOffset, to: todayStartDate) else { continue }
            let start = dayStartDate.timeIntervalSince1970
            let end = calendar.date(byAdding: .day, value: 1, to: dayStartDate)?.timeIntervalSince1970
                ?? (start + 86_400)
            days.append(Day(start: start, end: end, sameTime: start + elapsed))
        }
        guard let windowStart = days.first?.start, let windowEnd = days.last?.end else { return nil }

        var totals = [Double](repeating: 0, count: days.count)
        var byNow = [Double](repeating: 0, count: days.count)
        for (hour, cost) in hourAll {
            let h = Double(hour)
            guard h >= windowStart, h < windowEnd else { continue }
            // Days are contiguous and sorted; find the containing one.
            var low = 0
            var high = days.count - 1
            var index = -1
            while low <= high {
                let mid = (low + high) / 2
                if h < days[mid].start {
                    high = mid - 1
                } else if h >= days[mid].end {
                    low = mid + 1
                } else {
                    index = mid
                    break
                }
            }
            guard index >= 0 else { continue }
            totals[index] += cost
            let sameTime = days[index].sameTime
            if h + 3600 <= sameTime {
                byNow[index] += cost
            } else if h < sameTime {
                byNow[index] += cost * (sameTime - h) / 3600 // partial boundary hour
            }
        }

        var shares: [Double] = []
        for index in days.indices {
            // Skip quiet days: a day with almost no spend has a meaningless shape.
            guard totals[index] > 0.05 else { continue }
            shares.append(min(1, byNow[index] / totals[index]))
        }

        guard shares.count >= minimumDays else { return nil }
        shares.sort()
        let median = shares[shares.count / 2]
        guard median > 0.05 else { return nil }
        return todayCost / median
    }

    private static func sessionRow(digest: FileDigest, totals: TokenTotals, cost: Double, isLive: Bool) -> SessionRow {
        let model = digest.lastModel ?? ""
        let (projectName, _) = projectName(cwd: digest.cwd, projectDir: digest.projectDir)
        return SessionRow(
            path: digest.path,
            sessionId: digest.sessionId,
            source: digest.source,
            title: digest.title ?? "Untitled session",
            projectName: projectName,
            cwd: digest.cwd,
            gitBranch: digest.gitBranch,
            firstActive: digest.firstTs.map { Date(timeIntervalSince1970: $0) },
            lastActive: digest.lastTs.map { Date(timeIntervalSince1970: $0) },
            model: model,
            modelShortName: model.isEmpty ? "—" : ModelFamily.shortName(for: model),
            family: ModelFamily(model: model),
            totals: totals,
            cost: cost,
            contextTokens: digest.lastContextTokens,
            // The session's own observed window (Codex reports one per call)
            // beats the per-model table.
            contextLimit: digest.contextWindow ?? Pricing.contextWindow(for: model),
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
    ///
    /// Block boundaries chain forward from the first hour ever recorded, so this
    /// looks history-dependent — but a gap of a full block length always resets
    /// the chain. Any hour that far past the previous one is necessarily
    /// `>= blockStart + blockLength` (blockStart can never exceed the previous
    /// hour), so it opens a block regardless of what came before. Only the
    /// current unbroken run can affect the current block, and this walks back to
    /// find it instead of sorting every hour ever recorded on each rebuild —
    /// which happens every minute and on every filesystem event.
    static func currentBlock(hourAll: [Int64: (TokenTotals, Double)], nowEpoch: Double) -> BlockInfo? {
        guard !hourAll.isEmpty else { return nil }
        let blockSeconds = Int64(blockLength)
        let hour = 3600 as Int64

        var minHour = Int64.max
        var maxHour = Int64.min
        for key in hourAll.keys {
            minHour = min(minHour, key)
            maxHour = max(maxHour, key)
        }

        // Walk back an hour at a time from the newest activity. A stretch of
        // empty hours spanning a whole block length means the chain reset after
        // it, so nothing older matters.
        var runStart = maxHour
        var cursor = maxHour
        var emptyRun: Int64 = 0
        while cursor > minHour {
            cursor -= hour
            if hourAll[cursor] != nil {
                runStart = cursor
                emptyRun = 0
            } else {
                emptyRun += hour
                // The gap between the two active hours either side is one hour
                // wider than the empty stretch itself.
                if emptyRun + hour >= blockSeconds { break }
            }
        }

        var blockStart = runStart
        var scan = runStart
        while scan <= maxHour {
            if hourAll[scan] != nil, scan >= blockStart + blockSeconds { blockStart = scan }
            scan += hour
        }

        var totals = TokenTotals()
        var cost = 0.0
        var bucket = blockStart
        while bucket < blockStart + blockSeconds {
            if let agg = hourAll[bucket] {
                totals.add(agg.0)
                cost += agg.1
            }
            bucket += hour
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
