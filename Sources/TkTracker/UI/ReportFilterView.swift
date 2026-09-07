import SwiftUI

struct ReportFilterView: View {
    @Environment(UsageStore.self) private var store
    @State private var customDates = false
    var body: some View {
        @Bindable var store = store
        Form {
            Text("Filter & compare").font(.headline)
            Toggle("Current calendar month", isOn: $store.reportFilter.calendarMonth)
            Toggle("Custom dates", isOn: $customDates)
                .onChange(of: customDates) { _, value in
                    if value {
                        store.reportFilter.calendarMonth = false
                        if store.reportFilter.start == nil { store.reportFilter.start = Calendar.current.startOfDay(for: Date().addingTimeInterval(-7 * 86400)) }
                        if store.reportFilter.end == nil { store.reportFilter.end = Calendar.current.startOfDay(for: Date().addingTimeInterval(86400)) }
                    } else { store.reportFilter.start = nil; store.reportFilter.end = nil }
                }
            if customDates {
                DatePicker("From", selection: dateBinding(start: true), displayedComponents: .date)
                DatePicker("Through", selection: dateBinding(start: false), displayedComponents: .date)
            }
            Picker("Project", selection: $store.reportFilter.project) {
                Text("All projects").tag("")
                ForEach(projects, id: \.self) { Text($0).tag($0) }
            }
            Picker("Model", selection: $store.reportFilter.model) {
                Text("All models").tag("")
                ForEach(store.allModels, id: \.self) { Text(ModelIdentity.displayName($0)).tag($0) }
            }
            TextField("Saved view name", text: $store.reportFilter.name)
            HStack {
                Button("Save view") { store.saveCurrentFilter() }
                Button("Clear filters") { store.reportFilter = ReportFilter(); customDates = false }
            }
            ForEach(store.savedFilters) { saved in
                HStack {
                    Button(saved.name) { store.reportFilter = saved; customDates = saved.start != nil }
                    Spacer()
                    Button("Remove") {
                        store.savedFilters.removeAll { $0.id == saved.id }
                        if let data = try? JSONEncoder().encode(store.savedFilters) { UserDefaults.standard.set(data, forKey: "savedFilters") }
                    }.buttonStyle(.borderless)
                }
            }
        }.formStyle(.grouped).frame(width: 450, height: 490)
            .onAppear { customDates = store.reportFilter.start != nil }
    }
    private var projects: [String] { Array(Set(store.allDigests.map(\.projectKey))).sorted() }
    private func dateBinding(start: Bool) -> Binding<Date> {
        Binding(get: {
            start ? (store.reportFilter.start ?? Date()) : (store.reportFilter.end ?? Date()).addingTimeInterval(-1)
        }, set: { date in
            if start { store.reportFilter.start = Calendar.current.startOfDay(for: date) }
            else { store.reportFilter.end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: date)) }
            if let a = store.reportFilter.start, let b = store.reportFilter.end, a >= b {
                store.reportFilter.end = Calendar.current.date(byAdding: .day, value: 1, to: a)
            }
        })
    }
}
