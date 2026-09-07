import SwiftUI

struct BudgetSettings: View {
    @Environment(UsageStore.self) private var store
    var body: some View {
        @Bindable var store = store
        Form {
            Section("Monthly budgets") {
                Text("Budgets measure API-equivalent value across tracked profiles. Subscription payments remain separate.").font(.caption).foregroundStyle(.secondary)
                ForEach($store.budgetRules) { $rule in
                    VStack(alignment: .leading) {
                        TextField("Name", text: $rule.name)
                        Picker("Project", selection: $rule.project) {
                            Text("All projects").tag("")
                            ForEach(Array(Set(store.allDigests.map(\.projectKey))).sorted(), id: \.self) { Text($0).tag($0) }
                        }
                        TextField("Monthly limit (USD)", value: Binding(get: { rule.monthlyLimit }, set: { if $0.isFinite && $0 >= 0 { rule.monthlyLimit = $0 } }), format: .number)
                        Slider(value: $rule.warningFraction, in: 0.5...1, step: 0.05) { Text("Warn at") }
                        Text("Warn at \(Int(rule.warningFraction * 100))% and when exceeded").font(.caption)
                        Button("Remove budget") { store.budgetRules.removeAll { $0.id == rule.id } }
                    }.padding(.vertical, 5)
                }
                Button("Add monthly budget") { store.budgetRules.append(BudgetRule()) }
            }
            Section("Unusual spending") {
                Toggle("Alert when today's spend is unusually high", isOn: $store.anomalyAlerts)
                Text("Warns once a day when spend exceeds three times the median of at least five active days in the last two weeks, and exceeds $1.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

struct BudgetsCard: View {
    @Environment(UsageStore.self) private var store
    var body: some View {
        if !store.budgetProgress.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Monthly budgets").font(.headline)
                ForEach(store.budgetProgress) { progress in
                    VStack(alignment: .leading) {
                        HStack { Text(progress.rule.name); Spacer(); Text("\(Format.money(progress.used)) / \(Format.money(progress.rule.monthlyLimit))").monospacedDigit() }
                        ProgressView(value: min(progress.fraction, 1))
                            .tint(progress.fraction >= 1 ? .orange : Theme.accent)
                        if let projection = progress.projected { Text("Month-end at current daily pace: \(Format.money(projection))").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }.card()
        }
    }
}
