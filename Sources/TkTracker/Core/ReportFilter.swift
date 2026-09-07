import Foundation

struct ReportFilter: Codable, Equatable, Identifiable, Sendable {
    var id = UUID().uuidString
    var name = "Custom view"
    var start: Date?
    /// Exclusive upper bound.
    var end: Date?
    var calendarMonth = false
    var project: String = ""
    var model: String = ""

    func interval(now: Date, calendar: Calendar) -> DateInterval? {
        if calendarMonth { return calendar.dateInterval(of: .month, for: now) }
        guard let start, let end, end > start else { return nil }
        return DateInterval(start: start, end: end)
    }

    func apply(to digests: [FileDigest]) -> [FileDigest] {
        digests.compactMap { digest in
            guard project.isEmpty || digest.projectKey == project else { return nil }
            guard !model.isEmpty else { return digest }
            var d = digest
            d.buckets = d.buckets.filter { ModelIdentity.canonical($0.model) == ModelIdentity.canonical(model) }
            d.records = d.records?.filter { ModelIdentity.canonical($0.model) == ModelIdentity.canonical(model) }
            return d.accountingBuckets.isEmpty ? nil : d
        }
    }
}
