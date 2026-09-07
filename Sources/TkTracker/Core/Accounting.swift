import Foundation

enum ServiceTier: String, Codable, Sendable, CaseIterable {
    case unknown, standard, fast, batch, flex
    init(observed value: String?) {
        switch value?.lowercased() {
        case "priority", "fast": self = .fast
        case "default", "standard": self = .standard
        case "batch": self = .batch
        case "flex": self = .flex
        default: self = .unknown
        }
    }
}

struct PricingContext: Codable, Sendable, Equatable {
    var date: Date?
    var tier: ServiceTier = .unknown
    var promptTokens: Int64?
    var regional: Bool?
}

struct SessionMarker: Codable, Sendable, Equatable {
    var timestamp: Double
    var kind: String
}

struct PricingCoverage: Codable, Sendable, Equatable {
    var unpricedTokens: Int64 = 0
    var unpricedRequests: Int = 0
    var assumedTierRequests: Int = 0
    var legacyRequests: Int = 0
    var estimatedTokens: Int64 = 0
    var catalogUpdated: String = ""
    var isIncomplete: Bool { unpricedRequests > 0 || unpricedTokens > 0 }
    var note: String {
        var parts: [String] = []
        if isIncomplete { parts.append("\(Format.tokens(unpricedTokens)) tokens have no price; totals are partial") }
        if assumedTierRequests > 0 { parts.append("Standard rates assumed for \(assumedTierRequests) requests without a service tier") }
        if legacyRequests > 0 { parts.append("\(legacyRequests) archived requests retain hourly timing") }
        return parts.joined(separator: ". ")
    }
}
