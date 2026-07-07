import SwiftUI

struct SettingsView: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
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
                Text("0 disables. When today's cost crosses the budget, the menu bar icon switches to a warning and you get one notification per day (permission is requested the first time).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Launch at login", isOn: $store.launchAtLogin)
                VStack(alignment: .leading, spacing: 3) {
                    Toggle("Include pre-cleanup history (estimated)", isOn: $store.includeHistory)
                    Text("Claude Code deletes transcripts after ~30 days. Its aggregate stats survive; TkTracker uses them to reconstruct earlier usage per day and model, expanded by each model's lifetime cache mix.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Data") {
                    Text(store.dataRoot.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                LabeledContent("Cache") {
                    HStack {
                        Button("Rescan everything") {
                            Task { await store.resetCacheAndRescan() }
                        }
                        if store.isScanning {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
            }

            Section("About") {
                LabeledContent("Version", value: appVersion)
                Text("All data stays on this Mac. Costs are estimated from Anthropic list prices; deleted session files keep their history from the local scan cache.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { NSApp.activate() }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}
