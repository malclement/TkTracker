import Foundation

/// Stable billing identity. Display labels are never used as database keys.
enum ModelIdentity {
    static func canonical(_ raw: String) -> String {
        var id = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        id = id.replacingOccurrences(of: "[1m]", with: "")
        if let range = id.range(of: "claude-") { id = String(id[range.lowerBound...]) }
        else if id.hasPrefix("openai/") { id.removeFirst(7) }
        id = id.replacingOccurrences(of: #"(?:@\d{8}|-\d{8}|-\d{4}-\d{2}-\d{2})(?:-v\d+:\d+)?$"#, with: "", options: .regularExpression)
        id = id.replacingOccurrences(of: #"-v\d+:\d+$"#, with: "", options: .regularExpression)
        let aliases = ["gpt-5.6": "gpt-5.6-sol", "claude-3-5-sonnet-latest": "claude-3-5-sonnet",
                       "claude-3-7-sonnet-latest": "claude-3-7-sonnet", "claude-3-5-haiku-latest": "claude-3-5-haiku"]
        return aliases[id] ?? id
    }

    static func displayName(_ raw: String) -> String {
        let id = canonical(raw)
        if id.hasPrefix("gpt-") {
            let parts = id.dropFirst(4).split(separator: "-").map(String.init)
            guard let version = parts.first else { return raw }
            if parts.contains("codex") {
                let extras = parts.dropFirst().filter { $0 != "codex" }.map { $0.capitalized }.joined(separator: " ")
                return "Codex" + (extras.isEmpty ? "" : " " + extras) + " " + version
            }
            return "GPT-" + version + (parts.count > 1 ? " " + parts.dropFirst().map { $0.capitalized }.joined(separator: " ") : "")
        }
        if id == "codex-mini-latest" { return "Codex Mini" }
        if id.hasPrefix("claude-") {
            let parts = id.dropFirst(7).split(separator: "-").map(String.init)
            let families = ["opus", "sonnet", "haiku", "fable", "mythos", "instant"]
            guard let family = parts.first(where: { families.contains($0) }) else { return raw }
            let version = parts.filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) }.joined(separator: ".")
            let suffix = parts.contains("preview") ? " Preview" : ""
            return family.capitalized + (version.isEmpty ? "" : " " + version) + suffix
        }
        return raw
    }
}
