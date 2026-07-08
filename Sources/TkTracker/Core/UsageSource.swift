import Foundation

/// Where a session's usage comes from. Each source has its own data root,
/// session format, scan cache and history archive; digests from every enabled
/// source flow through the same aggregation pipeline.
enum UsageSource: String, Codable, Sendable, CaseIterable, Identifiable {
    case claude, codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// Terminal command that reopens a session, for the "copy resume" action.
    func resumeCommand(sessionId: String) -> String {
        switch self {
        case .claude: return "claude --resume \(sessionId)"
        case .codex: return "codex resume \(sessionId)"
        }
    }
}

/// What the UI is currently showing: everything, or a single source.
/// Persisted; applies to the menu bar figure, popover, dashboard, CSV and budget
/// alike, so every number on screen agrees about what it covers.
enum SourceScope: String, CaseIterable, Identifiable, Sendable {
    case all, claude, codex

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    var sources: Set<UsageSource> {
        switch self {
        case .all: return Set(UsageSource.allCases)
        case .claude: return [.claude]
        case .codex: return [.codex]
        }
    }
}
