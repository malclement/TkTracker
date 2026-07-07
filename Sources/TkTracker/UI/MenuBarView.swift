import SwiftUI

struct MenuBarView: View {
    @Environment(UsageStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let stats = store.stats
        VStack(alignment: .leading, spacing: 0) {
            header

            if !store.dataDirExists || (stats.allTimeCost == 0 && stats.totals.messages == 0 && !store.hasScanned) {
                EmptyDataView(scanning: store.isScanning, root: "~/.claude/projects")
                    .frame(height: 140)
            } else {
                hero(stats)
                HourSparkline(points: stats.hourly24, currentHour: currentHour)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)

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
    }

    private var currentHour: Date {
        Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 3600) * 3600)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("TKTRACKER")
                .font(.caption2.weight(.semibold))
                .kerning(1.2)
                .foregroundStyle(.secondary)
            if store.stats.activeSessions > 0 {
                LiveDot()
                Text("\(store.stats.activeSessions) live")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.isScanning {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func hero(_ stats: DashboardStats) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Format.money(stats.todayCost))
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .contentTransition(.numericText(value: stats.todayCost))
                .animation(.snappy(duration: 0.4), value: stats.todayCost)
            Text("today · \(Format.tokens(stats.todayTotals.total)) tokens · \(stats.todayTotals.messages) msgs")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func liveSection(_ stats: DashboardStats) -> some View {
        if stats.liveSessions.isEmpty {
            Text("No active sessions")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 16)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(stats.liveSessions) { session in
                    HStack(spacing: 8) {
                        LiveDot()
                        VStack(alignment: .leading, spacing: 1) {
                            Text(session.title)
                                .font(.callout)
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
            }
            .animation(.snappy(duration: 0.4), value: stats.liveSessions.map(\.cost))
            .padding(.horizontal, 16)
        }
    }

    private func footer(_ stats: DashboardStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    openWindow(id: "dashboard")
                    WindowFocus.promote()
                } label: {
                    Label("Dashboard", systemImage: "rectangle.on.rectangle")
                }
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
        }
        .padding(.top, 2)
    }
}
