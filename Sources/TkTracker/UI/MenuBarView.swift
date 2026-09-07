import SwiftUI

struct MenuBarView: View {
    @Environment(UsageStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let stats = store.stats
        let live = stats.activeSessions > 0
        VStack(alignment: .leading, spacing: 0) {
            header(stats)

            if !store.visibleDataDirExists || (stats.allTimeCost == 0 && stats.totals.messages == 0 && !store.hasScanned) {
                EmptyDataView(
                    scanning: store.isScanning,
                    roots: store.trackedRoots.map {
                        ($0.name, ($0.path as NSString).abbreviatingWithTildeInPath)
                    }
                )
                .frame(height: 140)
            } else {
                hero(stats)
                if stats.coverage.isIncomplete {
                    Text("Partial API value · some models have no price").font(.caption2).foregroundStyle(.orange).padding(.horizontal, 16)
                }
                HourSparkline(points: stats.hourly24, currentHour: currentHour)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                if let block = stats.block, block.isActive {
                    Divider().padding(.vertical, 10)
                    BlockGauge(block: block, now: stats.generatedAt)
                        .padding(.horizontal, 16)
                }

                Divider().padding(.vertical, 10)
                liveSection(stats)
            }

            Divider().padding(.top, 10)
            footer(stats)
        }
        .padding(.vertical, 12)
        .frame(width: 360)
        .background(alignment: .top) { glow(live) }
    }

    private var currentHour: Date {
        Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 3600) * 3600)
    }

    /// The popover's tell: a soft accent wash that breathes in while
    /// sessions are burning tokens and fades out when the desk goes quiet.
    private func glow(_ live: Bool) -> some View {
        RadialGradient(
            colors: [Theme.accent.opacity(0.16), .clear],
            center: UnitPoint(x: 0.5, y: -0.2),
            startRadius: 12,
            endRadius: 240
        )
        .frame(height: 190)
        .opacity(live ? 1 : 0)
        .animation(reduceMotion ? nil : .easeInOut(duration: 1.2), value: live)
        .allowsHitTesting(false)
    }

    private func header(_ stats: DashboardStats) -> some View {
        HStack(spacing: 8) {
            Eyebrow(text: Date.now.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
            Spacer()
            if store.showsSourceScope {
                sourceScopeMenu
            }
            if stats.activeSessions > 0 {
                HStack(spacing: 4.5) {
                    LiveDot()
                    Text("\(stats.activeSessions) live")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(Theme.good)
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(Capsule().fill(Theme.good.opacity(0.12)))
            }
            if store.isScanning {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    /// Compact lens switcher: every figure in the popover (and the menu bar)
    /// follows it, so what you see always agrees about what it covers.
    private var sourceScopeMenu: some View {
        @Bindable var store = store
        return Menu {
            Picker("Sources", selection: $store.sourceScope) {
                ForEach(SourceScope.allCases) { scope in
                    Text(scope == .all ? "All sources" : scope.label).tag(scope)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 8.5, weight: .bold))
                Text(store.sourceScope == .all ? "All sources" : store.sourceScope.label)
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(store.sourceScope == .all ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.accent))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Show usage from Claude Code, Codex, or both")
    }

    private func hero(_ stats: DashboardStats) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(Format.money(stats.todayCost))
                .font(Theme.metric(38))
                .contentTransition(.numericText(value: stats.todayCost))
                .animation(.snappy(duration: 0.4), value: stats.todayCost)
            Text("\(Format.tokens(stats.todayTotals.total)) tokens · \(stats.todayTotals.messages) messages today")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Both tools burning today: show how the figure splits.
            let claudeToday = stats.todayCost(for: .claude)
            let codexToday = stats.todayCost(for: .codex)
            if store.sourceScope == .all, claudeToday > 0.0005, codexToday > 0.0005 {
                Text("Claude Code \(Format.money(claudeToday)) · Codex \(Format.money(codexToday))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            let showBurn = stats.activeSessions > 0 && stats.burnRatePerHour > 0.01
            if showBurn || store.isOverBudget {
                HStack(spacing: 6) {
                    if showBurn {
                        Chip(
                            text: "\(Format.money(stats.burnRatePerHour))/h",
                            tint: Theme.serious,
                            icon: "flame.fill"
                        )
                        .help("Trailing-hour burn rate while sessions are active")
                    }
                    if store.isOverBudget {
                        Chip(
                            text: "Over \(Format.money(store.dailyBudget)) budget",
                            tint: Theme.critical,
                            icon: "exclamationmark.triangle.fill"
                        )
                        .help("Today's spend has crossed the daily budget set in Settings")
                    }
                }
                .padding(.top, 6)
            }
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func liveSection(_ stats: DashboardStats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "Live sessions")
            if stats.liveSessions.isEmpty {
                Text("No active sessions — costs update live while \(liveToolNames) runs.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(stats.liveSessions) { session in
                    HStack(spacing: 8) {
                        LiveDot()
                        VStack(alignment: .leading, spacing: 1) {
                            Text(session.title)
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            Text("\(session.projectName) · \(session.modelShortName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(Format.money(session.cost))
                                .font(.callout.weight(.medium).monospacedDigit())
                                .contentTransition(.numericText(value: session.cost))
                            ContextGauge(fraction: session.contextFraction)
                        }
                    }
                }
                .animation(.snappy(duration: 0.4), value: stats.liveSessions.map(\.cost))
            }
        }
        .padding(.horizontal, 16)
    }

    private var liveToolNames: String {
        let visible = store.visibleSources
        if visible == [.claude] { return "Claude Code" }
        if visible == [.codex] { return "Codex" }
        return "Claude Code or Codex"
    }

    private func footer(_ stats: DashboardStats) -> some View {
        HStack(spacing: 10) {
            Button {
                openWindow(id: "dashboard")
                WindowFocus.promote()
            } label: {
                Label("Dashboard", systemImage: "rectangle.on.rectangle")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut("d", modifiers: .command)

            Text("All time \(Format.money(stats.allTimeCost))")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()

            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("q", modifiers: .command)
            .help("Quit TkTracker")
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }
}
