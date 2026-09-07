import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            AccountSettings().tabItem { Label("Accounts", systemImage: "creditcard") }
            BudgetSettings().tabItem { Label("Budgets", systemImage: "chart.pie") }
            PricingSettings().tabItem { Label("Pricing", systemImage: "tag") }
            AdvancedSettings().tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 650, height: 660)
        .onAppear { NSApp.activate() }
    }
}

// MARK: - General

private struct GeneralSettings: View {
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
            }
        }
        .formStyle(.grouped)
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
}

// MARK: - Plan

// MARK: - Pricing

private struct PricingSettings: View {
    @Environment(UsageStore.self) private var store
    @State private var editing: [String: PricingOverride] = [:]

    var body: some View {
        Form {
            Section("Rates (USD per million tokens)") {
                Text("Catalog checked \(PricingCatalog.shared.updated). Prices are API-equivalent estimates, not subscription charges.").font(.caption).foregroundStyle(.secondary)
                if let notice = PricingCatalog.shared.reviewNotice() { Text(notice).foregroundStyle(.orange) }
                if let error = PricingCatalog.shared.lastError { Text(error).foregroundStyle(.red) }
                if store.allModels.isEmpty {
                    Text("No models seen yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.allModels, id: \.self) { model in
                        rateRow(model)
                    }
                }
            }

            Section {
                HStack {
                    Button("Reset all to defaults") {
                        for name in PricingCatalog.shared.allOverrides.keys {
                            PricingCatalog.shared.setOverride(nil, forShortName: name)
                        }
                        editing.removeAll()
                        store.operationError = PricingCatalog.shared.lastError
                store.refreshDerived()
                    }
                    .disabled(PricingCatalog.shared.overrideCount == 0)
                    Spacer()
                    Text("\(PricingCatalog.shared.overrideCount) override\(PricingCatalog.shared.overrideCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("""
                Rates ship in the app and are refreshed with app releases. Override a model when a rate goes \
                stale before TkTracker catches up, or when you have negotiated \
                pricing. Overrides win over the shipped table and survive updates.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func rateRow(_ model: String) -> some View {
        let name = ModelIdentity.canonical(model)
        let current = PricingCatalog.shared.pricing(for: model)
        let override = PricingCatalog.shared.override(forShortName: name)
        VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
            Swatch(color: store.colorScale.color(for: name, family: ModelFamily(model: model)))
            VStack(alignment: .leading, spacing: 1) {
                Text(ModelIdentity.displayName(model))
                Text(model)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if override != nil {
                Chip(text: "custom", tint: Theme.accent)
            }
            TextField("in", value: binding(for: name, current: current, keyPath: \.input), format: .number)
                .frame(width: 64)
                .multilineTextAlignment(.trailing)
            Text("/")
                .foregroundStyle(.tertiary)
            TextField("out", value: binding(for: name, current: current, keyPath: \.output), format: .number)
                .frame(width: 64)
                .multilineTextAlignment(.trailing)
            Button {
                PricingCatalog.shared.setOverride(nil, forShortName: name)
                editing.removeValue(forKey: name)
                store.operationError = PricingCatalog.shared.lastError
                store.refreshDerived()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .disabled(override == nil)
            .help("Reset \(name) to the shipped rate")
        }
        DisclosureGroup("Cache rates · USD / million tokens") {
            TextField("Cache read", value: cacheBinding(for: name, current: current, key: \.cacheRead), format: .number)
            TextField("Cache write 5m", value: cacheBinding(for: name, current: current, key: \.cacheWrite5m), format: .number)
            TextField("Cache write 1h", value: cacheBinding(for: name, current: current, key: \.cacheWrite1h), format: .number)
        }.font(.caption)
        }
    }

    private func cacheBinding(for name: String, current: ModelPricing?, key: WritableKeyPath<PricingOverride, Double?>) -> Binding<Double> {
        func initial() -> PricingOverride {
            PricingOverride(input: current?.input ?? 0, output: current?.output ?? 0,
                cacheRead: current?.cacheRead, cacheWrite5m: current?.cacheWrite5m, cacheWrite1h: current?.cacheWrite1h)
        }
        return Binding(get: { (editing[name] ?? PricingCatalog.shared.override(forShortName: name) ?? initial())[keyPath: key] ?? 0 }, set: { value in
            guard value.isFinite, value >= 0, value <= 1_000_000 else { return }
            var override = editing[name] ?? PricingCatalog.shared.override(forShortName: name) ?? initial()
            override[keyPath: key] = value
            PricingCatalog.shared.setOverride(override, forShortName: name)
            if PricingCatalog.shared.lastError == nil { editing[name] = override }
            store.operationError = PricingCatalog.shared.lastError
            store.refreshDerived()
        })
    }

    /// Edits both halves together: an override needs an input *and* an output, so
    /// typing in one field seeds the other from the currently effective rate.
    private func binding(
        for name: String,
        current: ModelPricing?,
        keyPath: WritableKeyPath<PricingOverride, Double>
    ) -> Binding<Double> {
        Binding(
            get: {
                if let staged = editing[name] { return staged[keyPath: keyPath] }
                if let override = PricingCatalog.shared.override(forShortName: name) {
                    return override[keyPath: keyPath]
                }
                let fallback = PricingOverride(input: current?.input ?? 0, output: current?.output ?? 0)
                return fallback[keyPath: keyPath]
            },
            set: { newValue in
                var staged = editing[name]
                    ?? PricingCatalog.shared.override(forShortName: name)
                    ?? PricingOverride(input: current?.input ?? 0, output: current?.output ?? 0)
                guard newValue.isFinite, newValue >= 0, newValue <= 1_000_000 else { return }
                staged[keyPath: keyPath] = newValue
                editing[name] = staged
                PricingCatalog.shared.setOverride(staged, forShortName: name)
                store.operationError = PricingCatalog.shared.lastError
                store.refreshDerived()
            }
        )
    }
}

// MARK: - Advanced

private struct AdvancedSettings: View {
    @Environment(UsageStore.self) private var store
    @State private var copiedDiagnostics = false

    var body: some View {
        @Bindable var store = store
        Form {
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $store.checksForUpdates)
                Text("""
                Off by default. When enabled it fetches the public releases \
                page from api.github.com at most once a day, sends nothing about \
                you or your usage, and never downloads or installs anything — it \
                shows you a version and a link.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack {
                    Button("Check now") {
                        Task { await store.updateChecker.check() }
                    }
                    Spacer()
                    updateStatus
                }
            }

            Section("Diagnostics") {
                if let problem = store.scanHealth.problemSummary {
                    NoticeBanner(text: problem)
                }
                LabeledContent("Last scan") {
                    Text(store.scanHealth.lastScan.map { Format.timeAgo($0) } ?? "never")
                }
                LabeledContent("Sessions tracked") {
                    Text("\(store.scanHealth.digestCount)")
                        .monospacedDigit()
                }
                LabeledContent("Scan time") {
                    Text(String(format: "%.0f ms", store.scanHealth.lastScanDuration * 1000))
                        .monospacedDigit()
                }
                HStack {
                    Button(copiedDiagnostics ? "Copied" : "Copy diagnostics") {
                        let report = Diagnostics.report(store: store)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report, forType: .string)
                        copiedDiagnostics = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            copiedDiagnostics = false
                        }
                    }
                    Spacer()
                }
                Text("Copies counts, sizes and timings for a bug report. Never includes project paths, session titles or prompts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("History & privacy") {
                Button("Export usage backup…") { store.exportBackup() }
                Button("Restore usage backup…") { store.restoreBackup() }
                Text("Backups contain usage metadata, project paths and titles. Restore merges missing sessions into configured accounts; existing sessions win.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Omit session titles", isOn: $store.privacyPolicy.omitTitles)
                Picker("Keep session detail metadata", selection: $store.privacyPolicy.detailRetentionDays) {
                    Text("Forever").tag(0)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("One year").tag(365)
                }
                Text("Retention removes old titles, context snapshots and compaction markers from TkTracker. Token, cost and branch accounting is kept. Source transcripts are unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Cache") {
                HStack {
                    Button("Rescan everything") {
                        Task { await store.resetCacheAndRescan() }
                    }
                    if store.isScanning {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }
                Text("Re-parses all transcripts on disk. Archived exact history of already-pruned sessions is kept.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Version", value: AppVersion.current)
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
    }

    @ViewBuilder
    private var updateStatus: some View {
        switch store.updateChecker.state {
        case .idle:
            Text(store.checksForUpdates ? "not checked yet" : "disabled")
                .font(.caption)
                .foregroundStyle(.tertiary)
        case .checking:
            ProgressView().controlSize(.small)
        case .upToDate:
            Text("\(AppVersion.current) · up to date")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .available(let version, let url, _):
            Link("\(version) available", destination: url)
                .font(.caption.weight(.semibold))
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(Theme.warning)
                .lineLimit(1)
                .help(message)
        }
    }
}
