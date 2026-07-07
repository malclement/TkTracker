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
    case overview, projects, sessions, models

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.50percent"
        case .projects: return "folder"
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
        } detail: {
            switch store.dashboardSection ?? .overview {
            case .overview: OverviewView()
            case .projects: ProjectsView()
            case .sessions: SessionsView()
            case .models: ModelsView()
            }
        }
        .navigationTitle("TkTracker")
        .onAppear { WindowFocus.promote() }
        .onDisappear { WindowFocus.demoteIfNoWindows() }
    }
}

struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder let trailing: Trailing

    init(title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title2.weight(.semibold))
            Spacer()
            trailing
            RangePicker()
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
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

    var body: some View {
        let stats = store.stats
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Overview") {
                    Button {
                        exportCSV()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderless)
                    .help("Export current range as CSV (per day and model)")
                }

                HStack(alignment: .top, spacing: 12) {
                    StatTile(
                        label: "Spend",
                        value: Format.money(stats.cost),
                        sub: spendSub(stats)
                    )
                    StatTile(
                        label: "Tokens",
                        value: Format.tokens(stats.totals.total),
                        sub: "\(Format.tokens(stats.totals.input)) in · \(Format.tokens(stats.totals.output)) out"
                    )
                    StatTile(
                        label: "Cache hit rate",
                        value: Format.percent(stats.cacheHitRate),
                        sub: stats.cacheSavings > 0.005 ? "saved ≈\(Format.money(stats.cacheSavings))" : "of prompt tokens"
                    )
                    StatTile(
                        label: "Sessions",
                        value: String(stats.sessions.count),
                        sub: stats.activeSessions > 0 ? "\(stats.activeSessions) live now" : "in range"
                    )
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

                if let coverage = coverageNote(stats) {
                    Text(coverage)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func spendSub(_ stats: DashboardStats) -> String {
        guard stats.range == .today else { return stats.range.label.lowercased() }
        if let delta = stats.todayVsYesterday {
            return "\(Format.signedPercent(delta)) vs yesterday by now"
        }
        return "since midnight"
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "tktracker-\(store.stats.range.rawValue).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Data(store.csvForCurrentRange().utf8).write(to: url)
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
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(metric == .cost ? "Spend by model" : "Tokens by model")
                    .font(.headline)
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
            .frame(height: 250)
        }
        .card()
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
        .padding(8)
        .frame(minWidth: 130)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.separator.opacity(0.6)))
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

        return VStack(alignment: .leading, spacing: 10) {
            Text("Model share")
                .font(.headline)
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
                            angularInset: 1.4
                        )
                        .cornerRadius(2.5)
                        .foregroundStyle(by: .value("Model", slice.name))
                    }
                    .chartForegroundStyleScale(
                        domain: names,
                        range: names.map { store.colorScale.color(for: $0) }
                    )
                    .chartLegend(.hidden)
                    .frame(width: 148, height: 148)
                    .overlay {
                        VStack(spacing: 0) {
                            Text(Format.money(stats.cost))
                                .font(.system(size: 17, weight: .semibold, design: .rounded))
                            Text("total")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
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
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func cacheCard(_ stats: DashboardStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Prompt cache")
                .font(.headline)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Format.percent(stats.cacheHitRate))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                Text("of prompt tokens read from cache")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ShareBar(fraction: stats.cacheHitRate, color: Theme.good)
            Text(stats.cacheSavings > 0.005
                 ? "≈\(Format.money(stats.cacheSavings)) saved vs uncached input"
                 : "write premiums currently outweigh reads")
                .font(.caption2)
                .foregroundStyle(.tertiary)
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
                Text("Current 5h block")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("No activity yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
