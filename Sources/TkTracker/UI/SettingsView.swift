import SwiftUI

struct SettingsView: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
            Section("Sources") {
                sourceToggle(
                    "Claude Code",
                    isOn: $store.trackClaude,
                    lastEnabled: store.trackClaude && !store.trackCodex,
                    path: store.dataRoot.path,
                    exists: store.dataDirExists
                )
                sourceToggle(
                    "Codex (OpenAI)",
                    isOn: $store.trackCodex,
                    lastEnabled: store.trackCodex && !store.trackClaude,
                    path: store.codexDataRoot.path,
                    exists: store.codexDataDirExists
                )
                Text("When both are on, the popover and dashboard get a filter to view either source or both together. Turning a source off hides it and stops scanning; its history returns when re-enabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Menu bar") {
                Picker("Show", selection: $store.menuBarDisplay) {
                    ForEach(MenuBarDisplay.allCases) { d in
                        Text(d.label).tag(d)
                    }
                }
                .pickerStyle(.inline)
            }

            Section("Budget") {
                TextField(
                    "Daily budget (USD)",
                    value: $store.dailyBudget,
                    format: .number.precision(.fractionLength(0...2))
                )
                Text("0 disables. When today's cost crosses the budget, the menu bar icon switches to a warning and you get one notification per day (permission is requested the first time). The budget watches all tracked sources, regardless of the view filter.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Launch at login", isOn: $store.launchAtLogin)
                VStack(alignment: .leading, spacing: 3) {
                    Toggle("Include pre-cleanup history (estimated)", isOn: $store.includeHistory)
                    Text("Claude Code deletes transcripts after ~30 days. Its aggregate stats survive; TkTracker uses them to reconstruct earlier usage per day and model, expanded by each model's lifetime cache mix. Only days from before you started using TkTracker are ever estimated — exact usage seen since then is archived locally and kept for good.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Cache") {
                    VStack(alignment: .trailing, spacing: 3) {
                        HStack {
                            Button("Rescan everything") {
                                Task { await store.resetCacheAndRescan() }
                            }
                            if store.isScanning {
                                ProgressView().controlSize(.small)
                            }
                        }
                        Text("Re-parses all transcripts on disk. Archived exact history of already-pruned sessions is kept.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("About") {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Source") {
                    Link("github.com/malclement/TkTracker",
                         destination: URL(string: "https://github.com/malclement/TkTracker")!)
                }
                Text("All data stays on this Mac. Costs are estimated from Anthropic and OpenAI list prices; deleted session files keep their exact history from a local archive that survives rescans.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { NSApp.activate() }
    }

    @ViewBuilder
    private func sourceToggle(
        _ title: String,
        isOn: Binding<Bool>,
        lastEnabled: Bool,
        path: String,
        exists: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(title, isOn: isOn)
                .disabled(lastEnabled) // at least one source stays on
            Text((path as NSString).abbreviatingWithTildeInPath
                 + (exists ? "" : " — not found"))
                .font(.caption.monospaced())
                .foregroundStyle(exists ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.warning))
                .textSelection(.enabled)
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}
