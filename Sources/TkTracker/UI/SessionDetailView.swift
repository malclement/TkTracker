import SwiftUI
import Charts

struct SessionDetailView: View {
    let digest: FileDigest
    let allDigests: [FileDigest]
    @Environment(\.dismiss) private var dismiss
    @State private var targetModel = "gpt-5.6-terra"

    private var records: [HourBucket] { digest.accountingBuckets.sorted { $0.epoch < $1.epoch } }
    private var family: [(digest: FileDigest, depth: Int)] {
        var result: [(FileDigest, Int)] = []
        var seen = Set<String>()
        func visit(_ d: FileDigest, _ depth: Int) {
            guard depth < 32, seen.insert(d.path).inserted else { return }
            result.append((d, depth))
            for child in allDigests.filter({ $0.parentSessionId == d.sessionId && $0.source == d.source && $0.profileId == d.profileId }).sorted(by: { $0.sessionId < $1.sessionId }) { visit(child, depth + 1) }
        }
        visit(digest, 0)
        return result
    }
    private var simulation: Double? {
        var amount = 0.0
        for record in records {
            guard PricingCatalog.shared.pricing(for: targetModel, context: record.context) != nil else { return nil }
            amount += Pricing.cost(model: targetModel, totals: record.totals, context: record.context)
        }
        return amount
    }
    private var timeline: [TimelinePoint] {
        var cumulative = 0.0
        let all = records
        let stride = max(1, all.count / 800)
        return all.enumerated().compactMap { i, record in
            cumulative += record.cost
            guard i % stride == 0 || i == all.count - 1 else { return nil }
            return TimelinePoint(id: i, date: Date(timeIntervalSince1970: record.epoch), cost: cumulative, context: record.contextTokens ?? 0)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text(digest.title ?? "Session details").font(.title2.bold()).lineLimit(2)
                    Text(digest.source.displayName + " · " + digest.sessionId).font(.caption.monospaced()).textSelection(.enabled)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        StatTile(label: "This session", value: Format.money(digest.cost), icon: "dollarsign.circle", sub: "API-equivalent value · full session")
                        StatTile(label: "Including subagents", value: Format.money(family.reduce(0) { $0 + $1.digest.cost }), icon: "person.3", sub: "\(family.count) session files")
                        StatTile(label: "Tokens", value: Format.tokens(digest.totals.total), icon: "number", sub: "\(digest.totals.messages) requests")
                    }
                    if records.contains(where: { PricingCatalog.shared.pricing(for: $0.model, context: $0.context) == nil }) { Text("Partial value: some requests have no verified price.").font(.caption).foregroundStyle(.orange) }
                    Text(digest.projectKey).font(.caption.monospaced()).textSelection(.enabled)
                    if digest.records == nil { Text("This archive retains hourly totals. Request timing and earlier model/branch changes cannot be recovered without the transcript.").font(.caption).foregroundStyle(.orange) }
                    VStack(alignment: .leading) {
                        Text("Cumulative API-equivalent value").font(.headline)
                        Chart(timeline) { point in
                            LineMark(x: .value("Time", point.date), y: .value("USD", point.cost))
                        }.frame(height: 180).accessibilityLabel("Cumulative session cost over time")
                        Text("Prompt context").font(.headline)
                        Chart(timeline) { point in
                            LineMark(x: .value("Time", point.date), y: .value("Tokens", point.context))
                        }.frame(height: 130).accessibilityLabel("Request context tokens over time")
                        ForEach(Array((digest.markers ?? []).enumerated()), id: \.offset) { _, marker in
                            Text("\(marker.kind) · \(Date(timeIntervalSince1970: marker.timestamp).formatted())").font(.caption)
                        }
                    }.card()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Agent tree").font(.headline)
                        if let parent = digest.parentSessionId { Text("Parent session: " + parent).font(.caption.monospaced()) }
                        ForEach(family, id: \.digest.path) { node in
                            HStack {
                                Text(node.digest.title ?? node.digest.sessionId).lineLimit(1)
                                    .padding(.leading, CGFloat(node.depth) * 18)
                                Spacer()
                                Text(Format.money(node.digest.cost)).monospacedDigit()
                            }
                        }
                    }.card()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Model cost simulation").font(.headline)
                        Picker("Reprice with", selection: $targetModel) {
                            ForEach(PricingCatalog.shared.knownModels, id: \.self) { Text(ModelIdentity.displayName($0)).tag($0) }
                        }
                        if let simulation {
                            Text("\(Format.money(simulation)) at the selected model's rates (difference \(Format.money(simulation - digest.cost)))").monospacedDigit()
                        } else { Text("This model has no verified price for one or more observed service tiers.").foregroundStyle(.orange) }
                        Text("Fixed token counts, cache categories and observed tiers. This compares rates; models can tokenize differently, require different output lengths and produce different results. Missing tiers use standard rates.").font(.caption).foregroundStyle(.secondary)
                    }.card()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Recent requests").font(.headline)
                        ForEach(Array(records.suffix(100).enumerated()), id: \.offset) { _, record in
                            HStack {
                                Text(Date(timeIntervalSince1970: record.epoch), style: .time).frame(width: 80, alignment: .leading)
                                Text(ModelIdentity.displayName(record.model)).frame(maxWidth: .infinity, alignment: .leading)
                                Text(record.branch ?? "—").lineLimit(1)
                                Text(record.context?.tier.rawValue ?? "unknown").foregroundStyle(.secondary)
                                Text(PricingCatalog.shared.pricing(for: record.model, context: record.context) == nil ? "Unpriced" : Format.money(record.cost)).monospacedDigit()
                            }.font(.caption)
                        }
                    }.card()
                }.padding()
            }
        }.frame(minWidth: 790, idealWidth: 860, minHeight: 600, idealHeight: 760)
    }
    private struct TimelinePoint: Identifiable {
        var id: Int
        var date: Date
        var cost: Double
        var context: Int64
    }
}
