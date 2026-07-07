import SwiftUI
import AppKit

// Sort helpers for optional/nested fields.
extension ProjectRow {
    var lastActiveSort: Date { lastActive ?? .distantPast }
    var tokensSort: Int64 { totals.total }
}

extension SessionRow {
    var lastActiveSort: Date { lastActive ?? .distantPast }
    var tokensSort: Int64 { totals.total }
    var contextSort: Double { contextFraction }
}

extension ModelRow {
    var tokensSort: Int64 { totals.total }
}

// MARK: - Projects

struct ProjectsView: View {
    @Environment(UsageStore.self) private var store
    @State private var sortOrder = [KeyPathComparator(\ProjectRow.cost, order: .reverse)]
    @State private var selection = Set<ProjectRow.ID>()

    private var rows: [ProjectRow] { store.stats.projects.sorted(using: sortOrder) }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Project", value: \.name) { p in
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.name)
                    Text(p.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.vertical, 2)
            }
            TableColumn("Sessions", value: \.sessions) { p in
                Text(String(p.sessions)).monospacedDigit()
            }
            .width(min: 60, ideal: 66, max: 80)
            TableColumn("Last active", value: \.lastActiveSort) { p in
                Text(p.lastActive.map { Format.timeAgo($0) } ?? "—")
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 92, max: 120)
            TableColumn("Tokens", value: \.tokensSort) { p in
                Text(Format.tokens(p.totals.total)).monospacedDigit()
            }
            .width(min: 66, ideal: 76, max: 96)
            TableColumn("Cost", value: \.cost) { p in
                Text(Format.money(p.cost)).monospacedDigit()
            }
            .width(min: 66, ideal: 78, max: 100)
            TableColumn("Share", value: \.share) { p in
                HStack(spacing: 7) {
                    ShareBar(fraction: p.share)
                    Text(Format.percent(p.share))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
            }
            .width(min: 100, ideal: 130, max: 170)
        }
        .tableStyle(.inset)
        .alternatingRowBackgrounds(.enabled)
        .contextMenu(forSelectionType: ProjectRow.ID.self) { ids in
            if let row = rows.first(where: { ids.contains($0.id) }) {
                Button("Show Sessions") { store.showSessions(filteredBy: row.name) }
                if row.path.hasPrefix("~") || row.path.hasPrefix("/") {
                    Button("Reveal in Finder") {
                        let expanded = (row.path as NSString).expandingTildeInPath
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: expanded)])
                    }
                }
            }
        } primaryAction: { ids in
            // Double-click drills into the project's sessions.
            if let row = rows.first(where: { ids.contains($0.id) }) {
                store.showSessions(filteredBy: row.name)
            }
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView(
                    "No activity in this range",
                    systemImage: "folder",
                    description: Text("Pick a wider range to see earlier projects.")
                )
            }
        }
        .background(Theme.canvas)
        .navigationTitle("Projects")
        .toolbar {
            ToolbarItem(placement: .principal) {
                RangePicker()
            }
        }
    }
}

// MARK: - Sessions

struct SessionsView: View {
    @Environment(UsageStore.self) private var store
    @State private var sortOrder = [KeyPathComparator(\SessionRow.lastActiveSort, order: .reverse)]
    @State private var selection = Set<SessionRow.ID>()

    private var rows: [SessionRow] {
        var r = store.stats.sessions
        let q = store.sessionSearch.lowercased()
        if !q.isEmpty {
            r = r.filter {
                $0.title.lowercased().contains(q)
                    || $0.projectName.lowercased().contains(q)
                    || $0.model.lowercased().contains(q)
            }
        }
        return r.sorted(using: sortOrder)
    }

    var body: some View {
        @Bindable var store = store
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Session", value: \.title) { s in
                HStack(spacing: 6) {
                    if s.isLive { LiveDot() }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.title).lineLimit(1)
                        Text(s.projectName + (s.missing ? " · history" : ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 2)
            }
            TableColumn("Model", value: \.modelShortName) { s in
                HStack(spacing: 5) {
                    Swatch(color: store.colorScale.color(for: s.modelShortName, family: s.family))
                    Text(s.modelShortName)
                        .font(.callout)
                }
            }
            .width(min: 84, ideal: 96, max: 120)
            TableColumn("Last active", value: \.lastActiveSort) { s in
                Text(s.lastActive.map { Format.timeAgo($0) } ?? "—")
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 92, max: 120)
            TableColumn("Context", value: \.contextSort) { s in
                ContextGauge(fraction: s.contextFraction)
            }
            .width(min: 78, ideal: 86, max: 110)
            TableColumn("Tokens", value: \.tokensSort) { s in
                Text(Format.tokens(s.totals.total)).monospacedDigit()
            }
            .width(min: 66, ideal: 76, max: 96)
            TableColumn("Cost", value: \.cost) { s in
                Text(Format.money(s.cost)).monospacedDigit()
            }
            .width(min: 66, ideal: 78, max: 100)
        }
        .tableStyle(.inset)
        .alternatingRowBackgrounds(.enabled)
        .contextMenu(forSelectionType: SessionRow.ID.self) { ids in
            if let row = rows.first(where: { ids.contains($0.id) }) {
                if let cwd = row.cwd {
                    Button("Reveal Project in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cwd)])
                    }
                }
                Button("Copy Resume Command") {
                    copyToPasteboard("claude --resume \(row.sessionId)")
                }
                Button("Copy Session ID") {
                    copyToPasteboard(row.sessionId)
                }
            }
        }
        .overlay {
            if rows.isEmpty {
                if store.sessionSearch.isEmpty {
                    ContentUnavailableView(
                        "No sessions in this range",
                        systemImage: "bubble.left.and.text.bubble.right",
                        description: Text("Pick a wider range to see earlier sessions.")
                    )
                } else {
                    ContentUnavailableView.search(text: store.sessionSearch)
                }
            }
        }
        .background(Theme.canvas)
        .navigationTitle("Sessions")
        .searchable(
            text: $store.sessionSearch,
            placement: .toolbar,
            prompt: "Title, project or model"
        )
        .toolbar {
            ToolbarItem(placement: .principal) {
                RangePicker()
            }
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Models

struct ModelsView: View {
    @Environment(UsageStore.self) private var store
    @State private var sortOrder = [KeyPathComparator(\ModelRow.cost, order: .reverse)]

    private var rows: [ModelRow] { store.stats.models.sorted(using: sortOrder) }

    var body: some View {
        Table(rows, sortOrder: $sortOrder) {
            TableColumn("Model", value: \.shortName) { m in
                HStack(spacing: 7) {
                    Swatch(color: store.colorScale.color(for: m.shortName, family: m.family))
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(m.shortName)
                            if !m.hasPricing {
                                Text("no pricing")
                                    .font(.caption2)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Theme.warning.opacity(0.2)))
                            }
                        }
                        Text(m.model)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
            TableColumn("Input") { m in
                Text(Format.tokens(m.totals.input)).monospacedDigit()
            }
            .width(min: 60, ideal: 70, max: 90)
            TableColumn("Output") { m in
                Text(Format.tokens(m.totals.output)).monospacedDigit()
            }
            .width(min: 60, ideal: 70, max: 90)
            TableColumn("Cache r / w") { m in
                Text("\(Format.tokens(m.totals.cacheRead)) / \(Format.tokens(m.totals.cacheWrite))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 118, max: 150)
            TableColumn("Msgs", value: \.totals.messages) { m in
                Text(String(m.totals.messages)).monospacedDigit()
            }
            .width(min: 52, ideal: 58, max: 76)
            TableColumn("Cost", value: \.cost) { m in
                Text(Format.money(m.cost)).monospacedDigit()
            }
            .width(min: 66, ideal: 78, max: 100)
            TableColumn("Share", value: \.share) { m in
                HStack(spacing: 7) {
                    ShareBar(fraction: m.share, color: store.colorScale.color(for: m.shortName, family: m.family))
                    Text(Format.percent(m.share))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
            }
            .width(min: 100, ideal: 130, max: 170)
        }
        .tableStyle(.inset)
        .alternatingRowBackgrounds(.enabled)
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView(
                    "No model activity in this range",
                    systemImage: "cpu",
                    description: Text("Pick a wider range to see earlier usage.")
                )
            }
        }
        .background(Theme.canvas)
        .navigationTitle("Models")
        .toolbar {
            ToolbarItem(placement: .principal) {
                RangePicker()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                Text("Costs are estimated from Anthropic list prices per model (cache reads 0.1×, 5m writes 1.25×, 1h writes 2× input; web search $10 per 1K requests). Subscription plans bill differently — treat these as API-equivalent value.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            .background(.bar)
        }
    }
}
