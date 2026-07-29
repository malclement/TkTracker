import Testing
import Foundation
@testable import TkTracker

@Suite("Plans, projection and updates")
struct PlanAndUpdateTests {
    // MARK: - Plan gauges

    @Test func planDefaultsToNoLimitsAtAll() {
        let plan = UsagePlan.none
        #expect(!plan.tracksBlock)
        #expect(!plan.tracksWeekly)
        #expect(!plan.tracksValue)

        // Nothing configured means no gauge is built, so the UI can never show
        // a threshold the user did not set.
        let stats = StatsBuilder.build(digests: [], range: .today, plan: plan)
        #expect(stats.blockGauge == nil)
        #expect(stats.weeklyGauge == nil)
        #expect(stats.planValueMultiple == nil)
    }

    @Test func planRoundTripsThroughDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "tktracker-plan-\(UUID().uuidString)"))
        defer { defaults.removeSuite(named: defaults.description) }

        #expect(UsagePlan.load(from: defaults) == .none)

        // An edited preset must keep its edits, not snap back to the preset.
        var plan = UsagePlan.preset(id: "max20")
        plan.blockLimit = 137.5
        plan.save(to: defaults)

        let loaded = UsagePlan.load(from: defaults)
        #expect(loaded.id == "max20")
        #expect(loaded.blockLimit == 137.5)
        #expect(loaded.monthlyCost == 200)
    }

    @Test func gaugeArithmetic() {
        let gauge = PlanGauge(used: 75, limit: 100, windowEnd: nil)
        #expect(gauge.fraction == 0.75)
        #expect(gauge.remaining == 25)
        #expect(!gauge.isNearLimit)
        #expect(!gauge.isOverLimit)

        let hot = PlanGauge(used: 85, limit: 100, windowEnd: nil)
        #expect(hot.isNearLimit)

        // Over the limit clamps the bar rather than overflowing it.
        let over = PlanGauge(used: 150, limit: 100, windowEnd: nil)
        #expect(over.fraction == 1)
        #expect(over.remaining == 0)
        #expect(over.isOverLimit)

        // A zero limit is "no gauge", not a division by zero.
        let off = PlanGauge(used: 10, limit: 0, windowEnd: nil)
        #expect(off.fraction == 0)
    }

    @Test func exhaustionOnlyPredictsInsideTheWindow() {
        let now = Date(timeIntervalSince1970: 1_783_000_000)
        let windowEnd = now.addingTimeInterval(3 * 3600)
        let gauge = PlanGauge(used: 50, limit: 100, windowEnd: windowEnd)

        // $25/h against $50 remaining runs out in 2h — inside the window.
        let soon = try? #require(gauge.exhaustion(ratePerHour: 25, now: now))
        #expect(soon?.timeIntervalSince(now) == 7200)

        // $5/h would take 10h, past the window close: nothing to warn about.
        #expect(gauge.exhaustion(ratePerHour: 5, now: now) == nil)
        // Idle predicts nothing.
        #expect(gauge.exhaustion(ratePerHour: 0, now: now) == nil)
        // Already over predicts nothing.
        #expect(PlanGauge(used: 100, limit: 100, windowEnd: windowEnd)
            .exhaustion(ratePerHour: 25, now: now) == nil)
    }

    @Test func gaugesTrackRollingWindowsNotTheSelectedRange() {
        // Range is the view; allowances are about real time. Selecting "Today"
        // must not make a weekly allowance look emptier than it is.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_783_468_800) // 2026-07-08 00:00 UTC

        func bucket(_ hoursAgo: Int64, cost outputTokens: Int64) -> HourBucket {
            let hour = Int64(now.timeIntervalSince1970) / 3600 * 3600 - hoursAgo * 3600
            var totals = TokenTotals()
            totals.output = outputTokens
            totals.messages = 1
            return HourBucket(hour: hour, model: "claude-opus-4-8", totals: totals)
        }

        var digest = FileDigest(path: "/a.jsonl", sessionId: "a", projectDir: "p")
        // 1M output tokens on Opus 4.8 = $25 each.
        digest.buckets = [
            bucket(100, cost: 1_000_000), // ~4 days ago: inside the week
            bucket(2, cost: 1_000_000),   // today
        ].sorted { $0.hour < $1.hour }

        var plan = UsagePlan.preset(id: "max20")
        plan.weeklyLimit = 100
        plan.blockLimit = 100

        let today = StatsBuilder.build(digests: [digest], range: .today, now: now, calendar: calendar, plan: plan)
        let month = StatsBuilder.build(digests: [digest], range: .month, now: now, calendar: calendar, plan: plan)

        // Same weekly figure regardless of which range is on screen.
        #expect(today.weeklyGauge?.used == month.weeklyGauge?.used)
        #expect(abs((today.weeklyGauge?.used ?? 0) - 50) < 0.001)
        // ...while the range totals genuinely differ.
        #expect(today.cost < month.cost)
    }

    @Test func valueMultipleUsesTrailingThirtyDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_783_468_800)
        let nowHour = Int64(now.timeIntervalSince1970) / 3600 * 3600

        var totals = TokenTotals()
        totals.output = 8_000_000 // Opus 4.8 at $25/MTok = $200
        totals.messages = 1
        var digest = FileDigest(path: "/a.jsonl", sessionId: "a", projectDir: "p")
        digest.buckets = [HourBucket(hour: nowHour - 3600, model: "claude-opus-4-8", totals: totals)]

        var plan = UsagePlan.preset(id: "max20") // $200/month
        plan.weeklyLimit = 0
        plan.blockLimit = 0

        let stats = StatsBuilder.build(digests: [digest], range: .today, now: now, calendar: calendar, plan: plan)
        #expect(abs((stats.rollingMonthCost) - 200) < 0.001)
        #expect(abs((stats.planValueMultiple ?? 0) - 1.0) < 0.001)
        // Limits left at zero stay invisible.
        #expect(stats.blockGauge == nil)
        #expect(stats.weeklyGauge == nil)
    }

    // MARK: - Projection

    @Test func projectionNeedsEnoughComparableDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let todayStart = 1_783_468_800.0 // 2026-07-08 00:00 UTC
        let now = todayStart + 6 * 3600 // 06:00, a quarter of the way in

        // Not enough history: say nothing rather than guess.
        #expect(StatsBuilder.projectedToday(
            hourAll: [Int64(todayStart) + 3600: 10], todayCost: 10,
            todayStart: todayStart, nowEpoch: now, calendar: calendar
        ) == nil)

        // Ten past days that each put a quarter of their spend before 06:00:
        // $10 by now out of $40 for the day.
        var hours: [Int64: Double] = [:]
        for day in 1...10 {
            let dayStart = Int64(todayStart) - Int64(day) * 86_400
            hours[dayStart + 3600] = 10 // before 06:00
            hours[dayStart + 12 * 3600] = 30 // after
        }
        hours[Int64(todayStart) + 3600] = 10 // today so far

        let projected = StatsBuilder.projectedToday(
            hourAll: hours, todayCost: 10,
            todayStart: todayStart, nowEpoch: now, calendar: calendar
        )
        // Median share is 0.25, so $10 so far projects to $40 — not the $240 a
        // naive burn-rate-to-midnight extrapolation would claim.
        #expect(abs((projected ?? 0) - 40) < 0.001)
    }

    @Test func projectionStaysQuietEarlyAndWhenIdle() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let todayStart = 1_783_468_800.0

        // Nothing spent yet.
        #expect(StatsBuilder.projectedToday(
            hourAll: [:], todayCost: 0,
            todayStart: todayStart, nowEpoch: todayStart + 7200, calendar: calendar
        ) == nil)

        // Minutes after midnight, any ratio would be wild.
        #expect(StatsBuilder.projectedToday(
            hourAll: [:], todayCost: 5,
            todayStart: todayStart, nowEpoch: todayStart + 600, calendar: calendar
        ) == nil)
    }

    // MARK: - Version comparison

    @Test func semanticVersionComparison() {
        #expect(AppVersion.isNewer("1.5.1", than: "1.5.0"))
        #expect(AppVersion.isNewer("1.6.0", than: "1.5.9"))
        #expect(AppVersion.isNewer("2.0.0", than: "1.99.99"))
        #expect(AppVersion.isNewer("1.10.0", than: "1.9.0")) // not string order
        #expect(!AppVersion.isNewer("1.5.0", than: "1.5.0"))
        #expect(!AppVersion.isNewer("1.4.9", than: "1.5.0"))

        // Short and pre-release forms must not crash or claim a false upgrade.
        #expect(!AppVersion.isNewer("1.5", than: "1.5.0"))
        #expect(AppVersion.isNewer("1.5.1-beta", than: "1.5.0"))
        #expect(!AppVersion.isNewer("garbage", than: "1.5.0"))
        #expect(AppVersion.components("1.5") == [1, 5, 0])
    }

    @Test func updateCheckerIsSilentUntilOptedIn() async throws {
        let defaults = try #require(UserDefaults(suiteName: "tktracker-update-\(UUID().uuidString)"))
        defer { defaults.removeSuite(named: defaults.description) }

        let checker = await UpdateChecker(defaults: defaults)
        // The privacy claim depends on this: disabled means no request at all,
        // not a request whose result is hidden.
        await checker.checkIfDue(enabled: false)
        let state = await checker.state
        #expect(state == .idle)
        let lastChecked = await checker.lastChecked
        #expect(lastChecked == nil)
    }
}
