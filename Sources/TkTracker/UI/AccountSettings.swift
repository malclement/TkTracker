import SwiftUI
import AppKit

struct AccountSettings: View {
    @Environment(UsageStore.self) private var store
    var body: some View {
        Form {
            ForEach(Array(store.profiles.enumerated()), id: \.element.id) { index, profile in
                Section(profile.name) {
                    Toggle("Track this profile", isOn: binding(index, \.enabled))
                    TextField("Name", text: binding(index, \.name))
                    HStack {
                        Text(profile.rootPath).font(.caption.monospaced()).lineLimit(2).textSelection(.enabled)
                        Spacer()
                        Button("Choose folder…") { chooseFolder(index) }
                    }
                    Label(FileManager.default.fileExists(atPath: profile.root.path) ? "Folder available" : "Folder missing — archived history is retained",
                          systemImage: FileManager.default.fileExists(atPath: profile.root.path) ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Last refresh: " + (store.scanHealth.lastScan.map { Format.timeAgo($0) } ?? "not yet scanned")).font(.caption)
                    Picker("Subscription", selection: Binding(get: { profile.plan.id }, set: { store.profiles[index].plan = UsagePlan.preset(id: $0) })) {
                        ForEach(UsagePlan.presets.filter { preset in
                            preset.id == "none" || preset.id == "custom" || (profile.source == .codex ? preset.id.hasPrefix("chatgpt") : !preset.id.hasPrefix("chatgpt"))
                        }) { preset in Text(preset.name).tag(preset.id) }
                    }
                    TextField("Monthly payment (USD)", value: planBinding(index, \.monthlyCost), format: .number)
                    TextField("Estimated 5h allowance (USD)", value: planBinding(index, \.blockLimit), format: .number)
                    TextField("Estimated rolling 7d allowance (USD)", value: planBinding(index, \.weeklyLimit), format: .number)
                    Text("Dollar allowances are your estimates. Observed vendor quotas appear separately. Zero hides an allowance.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Additional profile") {
                HStack {
                    ForEach(UsageSource.allCases) { source in
                        Button("Add \(source.displayName)") {
                            let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
                            panel.message = "Choose this profile's session folder."
                            if panel.runModal() == .OK, let url = panel.url {
                                let profile = SourceProfile(id: UUID().uuidString, name: source.displayName + " profile", source: source, rootPath: url.path)
                                let proposed = store.profiles + [profile]
                                if SourceProfile.unique(proposed).count == proposed.count { store.profiles = proposed }
                                else { store.operationError = "This folder is already tracked." }
                            }
                        }
                    }
                }
            }
            Section("Codex account quotas") {
                Toggle("Notify when observed quotas reach 80%", isOn: Binding(get: { store.quotaAlertsEnabled }, set: { store.quotaAlertsEnabled = $0 }))
                Toggle("Refresh quotas from the Codex account", isOn: Binding(get: { store.liveQuotasEnabled }, set: { store.liveQuotasEnabled = $0 }))
                Text("Optional. Runs your installed Codex CLI to read account limits once a minute. Codex handles authentication. Local session quota snapshots remain available without network access.").font(.caption).foregroundStyle(.secondary)
                TextField("Codex executable", text: Binding(get: { store.codexExecutable }, set: { store.codexExecutable = $0 }))
                Button(store.quotaRefreshing ? "Refreshing…" : "Refresh quotas") { Task { await store.refreshQuotas() } }
                    .disabled(!store.liveQuotasEnabled || store.quotaRefreshing)
                if let error = store.quotaError { Text(error).font(.caption).foregroundStyle(.orange) }
            }
        }.formStyle(.grouped)
    }
    private func binding<T>(_ index: Int, _ key: WritableKeyPath<SourceProfile, T>) -> Binding<T> {
        Binding(get: { store.profiles[index][keyPath: key] }, set: { store.profiles[index][keyPath: key] = $0 })
    }
    private func planBinding(_ index: Int, _ key: WritableKeyPath<UsagePlan, Double>) -> Binding<Double> {
        Binding(get: { store.profiles[index].plan[keyPath: key] }, set: { if $0.isFinite && $0 >= 0 { store.profiles[index].plan[keyPath: key] = $0 } })
    }
    private func chooseFolder(_ index: Int) {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            var proposed = store.profiles; proposed[index].rootPath = url.path
            if SourceProfile.unique(proposed).count == proposed.count { store.profiles = proposed }
            else { store.operationError = "This folder is already tracked." }
        }
    }
}

struct AccountsCard: View {
    @Environment(UsageStore.self) private var store
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Accounts & quotas").font(.headline)
            ForEach(store.stats.accounts) { account in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(account.name).font(.subheadline.weight(.semibold))
                        Spacer()
                        if account.monthlyPayment > 0 {
                            Text("\(Format.money(account.monthlyPayment))/month · \(Format.money(account.rollingValue)) API value in 30d").font(.caption)
                        }
                    }
                    if let quota = store.quotaSnapshots[account.id], !quota.windows.isEmpty {
                        ForEach(quota.windows) { window in
                            HStack {
                                Text(window.name).font(.caption)
                                ProgressView(value: window.usedPercent, total: 100).frame(maxWidth: 170)
                                Text("\(Int(window.remainingPercent))% left").monospacedDigit()
                                Text(window.resetsAt > Date() ? "Resets " + window.resetsAt.formatted(date: .abbreviated, time: .shortened) : "Reset passed — refresh needed").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Text("\(quota.origin) · \(Format.timeAgo(quota.observedAt))" + (quota.isStale() ? " · stale" : ""))
                            .font(.caption2).foregroundStyle(quota.isStale() ? .orange : .secondary)
                    } else {
                        Text("No observed quota available").font(.caption).foregroundStyle(.secondary)
                    }
                    if let weekly = account.weekly { Text("Estimated rolling 7d allowance: \(Format.money(weekly.used)) / \(Format.money(weekly.limit))").font(.caption) }
                    if let block = account.block { Text("Estimated activity block: \(Format.money(block.used)) / \(Format.money(block.limit))").font(.caption) }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).card()
    }
}
