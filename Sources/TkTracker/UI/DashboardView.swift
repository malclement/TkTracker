import SwiftUI
import AppKit
import Charts
import UniformTypeIdentifiers

extension ChartUnit {
    var calendarComponent: Calendar.Component {
        switch self {
        case .hour: return .hour
        case .day: return .day
        case .week: return .weekOfYear
        }
    }
}

enum DashboardSection: String, CaseIterable, Identifiable {
    case overview, projects, branches, sessions, models

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.50percent"
        case .projects: return "folder"
        case .branches: return "arrow.triangle.branch"
        case .sessions: return "bubble.left.and.text.bubble.right"
        case .models: return "cpu"
        }
    }
}

struct DashboardView: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            List(DashboardSection.allCases, selection: $store.dashboardSection) { s in
                Label(s.title, systemImage: s.icon).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 185, max: 230)
            .safeAreaInset(edge: .bottom) { sidebarFooter }
        } detail: {
            switch store.dashboardSection ?? .overview {
            case .overview: OverviewView()
            case .projects: ProjectsView()
            case .branches: BranchesView()
            case .sessions: SessionsView()
            case .models: ModelsView()
            }
        }
        .alert("TkTracker", isPresented: Binding(get: { store.operationError != nil }, set: { if !$0 { store.operationError = nil } })) {
            Button("OK") { store.operationError = nil }
        } message: { Text(store.operationError ?? "") }
        .onAppear { WindowFocus.promote() }
        .onDisappear { WindowFocus.demoteIfNoWindows() }
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 2) {
            Eyebrow(text: "All time")
            Text(Format.money(store.stats.allTimeCost))
                .font(Theme.metric(17))
                .contentTransition(.numericText())
            Label("All data stays on this Mac", systemImage: "lock.fill")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct RangePicker: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Picker("Range", selection: $store.range) {
            ForEach(StatsRange.allCases) { r in
                Text(r.label).tag(r)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 300)
    }
}

/// One lens over the data sources — everything on screen follows it.
struct SourceScopePicker: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Picker("Sources", selection: $store.sourceScope) {
            ForEach(SourceScope.allCases) { scope in
                Text(scope.label).tag(scope)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 190)
        .help("Show usage from Claude Code, Codex, or both")
    }
}

/// Shared toolbar content: the time range plus, when more than one source is
/// tracked, the source lens.
struct FilterBar: View {
    @State private var showingFilters = false
    @Environment(UsageStore.self) private var store

    var body: some View {
        HStack(spacing: 10) {
            RangePicker()
            Button { showingFilters.toggle() } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                .help("Custom dates, project/model filters and saved views")
                .popover(isPresented: $showingFilters) { ReportFilterView().environment(store) }
            if store.showsSourceScope {
                SourceScopePicker()
            }
        }
    }
}

// MARK: - Overview

private enum ChartMetric: String, CaseIterable, Identifiable {
    case cost = "Cost"
    case tokens = "Tokens"
    var id: String { rawValue }
}

struct OverviewView: View {
    @Environment(UsageStore.self) private var store
    @State private var metric: ChartMetric = .cost
    @State private var selectedDate: Date?
    @State private var donutAngle: Double?

    var body: some View {
        let stats = store.stats
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                banners

                tiles(stats)
                if !stats.coverage.note.isEmpty {
                    Text(stats.coverage.note).font(.caption).foregroundStyle(stats.coverage.isIncomplete ? .orange : .secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).card()
                }
                if let previous = stats.previousPeriodCost {
                    Text("Previous comparable period: \(Format.money(previous)) · Change: \(Format.money(stats.cost - previous))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                AccountsCard()
                BudgetsCard()

                if stats.blockGauge != nil || stats.weeklyGauge != nil {
                    allowanceCard(stats)
                }

                spendChart(stats)

                HStack(alignment: .top, spacing: 12) {
                    modelDonut(stats)
                    VStack(spacing: 12) {
                        cacheCard(stats)
                        blockCard(stats)
                    }
                    .frame(maxWidth: .infinity)
                }

                if !stats.heatmap.isEmpty {
                    ActivityHeatmap(cells: stats.heatmap).card()
                }

                if let coverage = coverageNote(stats) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: "info.circle")
                        Text(coverage)
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }
            .padding(20)
        }
        .background(Theme.canvas)
        .navigationTitle("Overview")
        .toolbar {
            ToolbarItem(placement: .principal) {
                FilterBar()
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Export CSV…") { export(.csv) }
                    Button("Export JSON…") { export(.json) }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Export the current range — CSV per day/source/model, or the full stats as JSON")
            }
        }
    }

    /// The four headline tiles. Two slots are adaptive: today's view swaps
    /// Tokens for a projection, and a configured plan swaps Sessions for the
    /// value multiple. Split out of the body because the whole row in one
    /// expression pushed the type checker past its budget.
    private func tiles(_ stats: DashboardStats) -> some View {
        HStack(alignment: .top, spacing: 12) {
            StatTile(
                label: stats.coverage.isIncomplete ? "API value (partial)" : "API-equivalent value",
                value: Format.money(stats.cost),
                icon: "dollarsign.circle",
                sub: spendSub(stats),
                delta: stats.range == .today ? stats.todayVsYesterday : nil,
                deltaLabel: "vs yesterday by now"
            )
            secondTile(stats)
            StatTile(
                label: "Cache hit rate",
                value: Format.percent(stats.cacheHitRate),
                icon: "bolt.fill",
                sub: stats.cacheHitRate > 0 ? "of prompt tokens" : "no cached prompts yet"
            )
            fourthTile(stats)
        }
    }

    @ViewBuilder
    private func secondTile(_ stats: DashboardStats) -> some View {
        if stats.range == .today, let projected = stats.projectedTodayCost {
            StatTile(
                label: "Projected today",
                value: Format.money(projected),
                icon: "chart.line.uptrend.xyaxis",
                sub: "from how your days usually run"
            )
            .help("Today's spend divided by the share of a typical day's spend that has normally landed by this hour, measured over the last three weeks of active days.")
        } else {
            StatTile(
                label: "Tokens",
                value: Format.tokens(stats.totals.total),
                icon: "number",
                sub: "\(Format.tokens(stats.totals.input)) in · \(Format.tokens(stats.totals.output)) out"
            )
        }
    }

    @ViewBuilder
    private func fourthTile(_ stats: DashboardStats) -> some View {
        if let multiple = stats.planValueMultiple {
            StatTile(
                label: "Plan value",
                value: Format.multiple(multiple),
                icon: "creditcard",
                sub: "\(Format.money(stats.rollingMonthCost)) of \(Format.money(store.plan.monthlyCost)) · 30d"
            )
            .help("API-equivalent value over the last 30 days, divided by what your plan costs per month.")
        } else {
            StatTile(
                label: "Sessions",
                value: String(stats.sessions.count),
                icon: "bubble.left.and.bubble.right",
                sub: stats.activeSessions > 0 ? "\(stats.activeSessions) live now" : "in range"
            )
        }
    }

    /// Scan problems and update availability, above everything else — a wrong
    /// number is worse than a missing one, so say when the data is incomplete.
    @ViewBuilder
    private var banners: some View {
        if let problem = store.scanHealth.problemSummary {
            NoticeBanner(
                text: "\(problem). Figures below may be incomplete.",
                actionTitle: "Details",
                action: { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
            )
        }
        if case .available(let version, let url, _) = store.updateChecker.state {
            NoticeBanner(
                text: "TkTracker \(version) is available.",
                icon: "arrow.down.circle.fill",
                tint: Theme.accent,
                actionTitle: "Release notes",
                action: { NSWorkspace.shared.open(url) }
            )
        }
    }

    /// Plan allowance gauges. Only rendered when the user configured a limit.
    private func allowanceCard(_ stats: DashboardStats) -> some View {
        HStack(alignment: .top, spacing: 20) {
            if let gauge = stats.blockGauge {
                AllowanceGauge(
                    title: "5-hour block",
                    gauge: gauge,
                    exhaustsAt: gauge.exhaustion(ratePerHour: stats.burnRatePerHour, now: stats.generatedAt),
                    footnote: stats.block.map {
                        "Window ends \($0.end.formatted(date: .omitted, time: .shortened))"
                    }
                )
            }
            if let gauge = stats.weeklyGauge {
                AllowanceGauge(
                    title: "This week",
                    gauge: gauge,
                    footnote: "Rolling 7 days · \(Format.money(gauge.remaining)) of allowance left"
                )
            }
        }
        .card()
    }

    private func spendSub(_ stats: DashboardStats) -> String? {
        guard stats.range == .today else { return stats.range.label.lowercased() }
        return stats.todayVsYesterday == nil ? "since midnight" : nil
    }

    private enum ExportFormat {
        case csv, json
        var type: UTType { self == .csv ? .commaSeparatedText : .json }
        var ext: String { self == .csv ? "csv" : "json" }
    }

    private func export(_ format: ExportFormat) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.type]
        panel.nameFieldStringValue = "tktracker-\(store.stats.range.rawValue).\(format.ext)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text: String
            switch format {
            case .csv: text = store.csvForCurrentRange()
            case .json: text = try store.jsonForCurrentRange()
            }
            try Data(text.utf8).write(to: url)
        } catch {
            Diagnostics.app.error("export failed: \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Export failed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func coverageNote(_ stats: DashboardStats) -> String? {
        guard let since = stats.dataSince else { return nil }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        var note = "Usage history since \(f.string(from: since))."
        if stats.hasEstimatedHistory {
            note += " Days before the oldest surviving transcript are estimated from Claude Code's"
                + " stats cache — Claude Code prunes transcripts after ~30 days (cleanupPeriodDays)."
                + " Toggle in Settings."
        }
        return note
    }

    // MARK: Spend chart

    private func spendChart(_ stats: DashboardStats) -> some View {
        let names = presentModelNames(stats)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Eyebrow(
                    text: metric == .cost ? "Spend by model" : "Tokens by model",
                    icon: "chart.bar.fill"
                )
                Spacer()
                Picker("Metric", selection: $metric) {
                    ForEach(ChartMetric.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
            }

            Chart {
                ForEach(stats.chart) { point in
                    BarMark(
                        x: .value("Date", point.date, unit: stats.chartUnit.calendarComponent),
                        y: .value(metric.rawValue, metric == .cost ? point.cost : Double(point.tokens)),
                        width: .ratio(0.62)
                    )
                    .foregroundStyle(by: .value("Model", point.modelName))
                    .cornerRadius(2.5)
                }
                if let selectedDate, let summary = selectionSummary(stats, at: selectedDate) {
                    RuleMark(x: .value("Selected", summary.date, unit: stats.chartUnit.calendarComponent))
                        .foregroundStyle(.quaternary)
                        .zIndex(-1)
                        .annotation(
                            position: .top,
                            spacing: 6,
                            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                        ) {
                            selectionCard(summary)
                        }
                }
            }
            .chartForegroundStyleScale(
                domain: names,
                range: names.map { store.colorScale.color(for: $0) }
            )
            .chartLegend(names.count > 1 ? .visible : .hidden)
            .chartLegend(position: .top, alignment: .trailing, spacing: 6)
            .chartXSelection(value: $selectedDate)
            .chartYAxis {
                AxisMarks(position: .trailing) { value in
                    AxisGridLine().foregroundStyle(.quaternary.opacity(0.6))
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(metric == .cost ? Format.money(v) : Format.tokens(Int64(v)))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisValueLabel(
                        format: stats.chartUnit == .hour
                            ? .dateTime.hour()
                            : .dateTime.day().month(.abbreviated)
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(height: 260)
            .accessibilityLabel(metric == .cost ? "Spend by model over time" : "Tokens by model over time")
            .accessibilityValue(chartSummary(stats))
        }
        .card()
    }

    /// Charts are unreadable to VoiceOver by default. Summarize the shape rather
    /// than enumerating every bar.
    private func chartSummary(_ stats: DashboardStats) -> String {
        guard !stats.chart.isEmpty else { return "no data in this range" }
        let unit = stats.chartUnit == .hour ? "hour" : (stats.chartUnit == .week ? "week" : "day")
        let top = stats.models.prefix(3).map { "\($0.shortName) \(Format.money($0.cost))" }
        return "\(stats.chart.count) \(unit) segments, total \(Format.money(stats.cost)). "
            + "Top models: \(top.joined(separator: ", "))."
    }

    private func presentModelNames(_ stats: DashboardStats) -> [String] {
        let present = Set(stats.chart.map(\.modelName))
        return stats.modelPalette.map(\.name).filter(present.contains)
    }

    private struct SelectionSummary {
        let date: Date
        let rows: [(name: String, cost: Double, tokens: Int64)]
        var totalCost: Double { rows.reduce(0) { $0 + $1.cost } }
        var totalTokens: Int64 { rows.reduce(0) { $0 + $1.tokens } }
    }

    private func selectionSummary(_ stats: DashboardStats, at date: Date) -> SelectionSummary? {
        let dates = Set(stats.chart.map(\.date))
        guard let nearest = dates.min(by: {
            abs($0.timeIntervalSince(date)) < abs($1.timeIntervalSince(date))
        }) else { return nil }
        let width = stats.chartUnit.seconds
        guard abs(nearest.timeIntervalSince(date)) <= width else { return nil }
        let index = Dictionary(uniqueKeysWithValues: stats.modelPalette.enumerated().map { ($1.name, $0) })
        let rows = stats.chart
            .filter { $0.date == nearest }
            .map { (name: $0.modelName, cost: $0.cost, tokens: $0.tokens) }
            .sorted { (index[$0.name] ?? 99) < (index[$1.name] ?? 99) }
        return SelectionSummary(date: nearest, rows: rows)
    }

    private func selectionCard(_ summary: SelectionSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(selectionDateLabel(summary.date))
                .font(.caption.weight(.semibold))
            ForEach(summary.rows, id: \.name) { row in
                HStack(spacing: 5) {
                    Swatch(color: store.colorScale.color(for: row.name))
                    Text(row.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(metric == .cost ? Format.money(row.cost) : Format.tokens(row.tokens))
                        .font(.caption.monospacedDigit())
                }
            }
            Divider()
            HStack {
                Text("Total").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(metric == .cost ? Format.money(summary.totalCost) : Format.tokens(summary.totalTokens))
                    .font(.caption.weight(.semibold).monospacedDigit())
            }
        }
        .padding(9)
        .frame(minWidth: 130)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.10), radius: 6, x: 0, y: 2)
    }

    private func selectionDateLabel(_ date: Date) -> String {
        switch store.stats.chartUnit {
        case .hour:
            return date.formatted(.dateTime.hour().minute())
        case .day:
            return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        case .week:
            return "Week of " + date.formatted(.dateTime.day().month(.abbreviated))
        }
    }

    // MARK: Donut + side cards

    private func modelDonut(_ stats: DashboardStats) -> some View {
        let byName = Dictionary(grouping: stats.models.filter { $0.cost > 0 }, by: \.shortName)
            .map { (name: $0.key, cost: $0.value.reduce(0) { $0 + $1.cost }) }
        let index = Dictionary(uniqueKeysWithValues: stats.modelPalette.enumerated().map { ($1.name, $0) })
        let slices = byName.sorted { (index[$0.name] ?? 99) < (index[$1.name] ?? 99) }
        let names = slices.map(\.name)
        let selected = selectedSlice(in: slices)

        return VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "Model share", icon: "chart.pie.fill")
            if slices.isEmpty {
                Text("No spend in range")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                HStack(spacing: 18) {
                    Chart(slices, id: \.name) { slice in
                        SectorMark(
                            angle: .value("Cost", slice.cost),
                            innerRadius: .ratio(0.64),
                            outerRadius: .ratio(selected == nil || selected?.name == slice.name ? 1.0 : 0.92),
                            angularInset: 1.4
                        )
                        .cornerRadius(2.5)
                        .foregroundStyle(by: .value("Model", slice.name))
                        .opacity(selected == nil || selected?.name == slice.name ? 1 : 0.35)
                    }
                    .chartForegroundStyleScale(
                        domain: names,
                        range: names.map { store.colorScale.color(for: $0) }
                    )
                    .chartLegend(.hidden)
                    .chartAngleSelection(value: $donutAngle)
                    .animation(.smooth(duration: 0.25), value: selected?.name)
                    .frame(width: 148, height: 148)
                    .overlay {
                        VStack(spacing: 0) {
                            Text(Format.money(selected?.cost ?? stats.cost))
                                .font(Theme.metric(17))
                                .contentTransition(.numericText())
                            Text(selected?.name ?? "total")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: 86)
                        .animation(.smooth(duration: 0.25), value: selected?.name)
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(stats.models.prefix(6)) { m in
                            HStack(spacing: 6) {
                                Swatch(color: store.colorScale.color(for: m.shortName, family: m.family))
                                Text(m.shortName)
                                    .font(.caption)
                                    .lineLimit(1)
                                Spacer(minLength: 10)
                                Text(Format.money(m.cost))
                                    .font(.caption.monospacedDigit())
                                Text(Format.percent(m.share))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 34, alignment: .trailing)
                            }
                            .opacity(selected == nil || selected?.name == m.shortName ? 1 : 0.45)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    /// Maps the donut's angle selection back to a slice via cumulative cost.
    private func selectedSlice(in slices: [(name: String, cost: Double)])
        -> (name: String, cost: Double)? {
        guard let donutAngle else { return nil }
        var cumulative = 0.0
        for slice in slices {
            cumulative += slice.cost
            if donutAngle <= cumulative { return slice }
        }
        return slices.last
    }

    private func cacheCard(_ stats: DashboardStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "Prompt cache", icon: "bolt.fill")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Format.percent(stats.cacheHitRate))
                    .font(Theme.metric(22))
                    .contentTransition(.numericText())
                Text("of prompt tokens read from cache")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ShareBar(fraction: stats.cacheHitRate, color: Theme.good)
            if stats.cacheSavings > 0.005 {
                Text("≈\(Format.money(stats.cacheSavings)) saved vs uncached input")
                    .font(.caption2)
                    .foregroundStyle(Theme.good)
            } else {
                Text("write premiums currently outweigh reads")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    @ViewBuilder
    private func blockCard(_ stats: DashboardStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let block = stats.block {
                BlockGauge(block: block, now: stats.generatedAt)
            } else {
                Eyebrow(text: "Current 5h block", icon: "clock")
                Text("No activity yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
