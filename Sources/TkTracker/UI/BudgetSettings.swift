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
            VStack(alignment: .leading, spacing: 12) {
                Eyebrow(text: "Monthly budgets", icon: "gauge.with.needle")
                ForEach(store.budgetProgress) { progress in
                    let tint = progress.fraction >= 1
                        ? Theme.critical
                        : Theme.fillColor(progress.fraction, calm: Theme.accent)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(progress.rule.name).font(.subheadline.weight(.medium))
                            Spacer(minLength: 8)
                            Text("\(Format.money(progress.used)) of \(Format.money(progress.rule.monthlyLimit))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(Format.percent(progress.fraction))
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(tint)
                                .frame(minWidth: 34, alignment: .trailing)
                        }
                        ShareBar(fraction: progress.fraction, color: tint, height: 6)
                        if let projection = progress.projected {
                            Text("Month-end at current daily pace: \(Format.money(projection))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(progress.rule.name)
                    .accessibilityValue("\(Format.money(progress.used)) of \(Format.money(progress.rule.monthlyLimit))")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
    }
}
