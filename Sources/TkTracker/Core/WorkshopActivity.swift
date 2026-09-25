import Foundation

/// Ephemeral activity, deliberately separate from the usage archive. No prompts,
/// tool arguments or outputs are retained by the workshop.
enum WorkshopState: String, Sendable, CaseIterable {
    case working, usingTool, waitingForAgents, needsInput, idle, completed, interrupted, unavailable

    var label: String {
        switch self {
        case .working: return "Working"
        case .usingTool: return "Using a tool"
        case .waitingForAgents: return "Waiting for agents"
        case .needsInput: return "Needs you"
        case .idle: return "Idle"
        case .completed: return "Turn complete"
        case .interrupted: return "Interrupted"
        case .unavailable: return "Status unavailable"
        }
    }
    var symbol: String {
        switch self {
        case .working: return "sparkles"
        case .usingTool: return "terminal"
        case .waitingForAgents: return "person.2"
        case .needsInput: return "hand.raised.fill"
        case .idle: return "moon.zzz"
        case .completed: return "checkmark.circle.fill"
        case .interrupted: return "pause.circle.fill"
        case .unavailable: return "questionmark.circle"
        }
    }
    var isWorking: Bool { self == .working || self == .usingTool }
}

/// Which kind of tool an agent is using, sorted from the tool name only. The
/// arguments are never read, so this is as private as the state itself.
enum WorkshopToolKind: String, Sendable, CaseIterable {
    case search, read, edit, run, delegate, other

    init(toolName: String) {
        let name = toolName.lowercased()
        if name.contains("spawn_agent") || name == "agent" || name == "task" { self = .delegate }
        else if name.contains("patch") || name == "edit" || name == "write" || name == "multiedit" || name == "notebookedit" { self = .edit }
        else if name.contains("search") || name.contains("web") || name == "grep" || name == "glob" { self = .search }
        else if name == "read" || name.contains("read_file") { self = .read }
        else if name.contains("exec") || name == "bash" || name.contains("terminal") || name.contains("shell") { self = .run }
        else { self = .other }
    }

    var label: String {
        switch self {
        case .search: return "Searching"
        case .read: return "Reading files"
        case .edit: return "Editing files"
        case .run: return "Running a tool"
        case .delegate: return "Delegating to a subagent"
        case .other: return "Using a tool"
        }
    }
}

struct WorkshopEvent: Identifiable, Equatable, Sendable {
    var id: String
    var date: Date
    var state: WorkshopState
    var label: String
}

struct WorkshopAgent: Identifiable, Equatable, Sendable {
    var id: String
    var sessionID: String
    var profileID: String
    var source: UsageSource
    var parentSessionID: String?
    var projectPath: String
    var title: String
    var model: String?
    var digestPath: String?
    var state: WorkshopState
    var activity: String
    /// Set only while `state == .usingTool`.
    var tool: WorkshopToolKind? = nil
    var lastActivity: Date?
    var openedAt: Date
    var presenceConfirmed: Bool = true
    var events: [WorkshopEvent] = []

    var projectName: String { URL(fileURLWithPath: projectPath).lastPathComponent.nonEmpty ?? "Workspace" }
    var parentID: String? { parentSessionID.map { Self.key(profile: profileID, source: source, session: $0) } }
    static func key(profile: String, source: UsageSource, session: String) -> String { "\(source.rawValue)|\(profile)|\(session)" }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

struct WorkshopIsland: Identifiable, Equatable {
    var lead: WorkshopAgent
    var subagents: [WorkshopAgent]
    var id: String { lead.id }
    var agents: [WorkshopAgent] { [lead] + subagents }

    /// Resolve arbitrary-depth delegation once. Bad/cyclic metadata cannot
    /// duplicate agents, recurse forever, or hide a whole team.
    static func group(_ agents: [WorkshopAgent]) -> [WorkshopIsland] {
        let lookup = Dictionary(agents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func root(of agent: WorkshopAgent) -> String {
            var current = agent
            var visited: [String] = []
            while true {
                if let start = visited.firstIndex(of: current.id) { return visited[start...].min() ?? current.id }
                visited.append(current.id)
                guard let parent = current.parentID.flatMap({ lookup[$0] }) else { return current.id }
                current = parent
            }
        }
        let groups = Dictionary(grouping: lookup.values, by: root)
        return groups.compactMap { key, members in
            guard let lead = lookup[key] else { return nil }
            return WorkshopIsland(lead: lead, subagents: members.filter { $0.id != key }.sorted { $0.id < $1.id })
        }.sorted { ($0.lead.openedAt, $0.id) < ($1.lead.openedAt, $1.id) }
    }
}

/// Absence only closes a session after two successful observations. Failed
/// probes preserve islands as unavailable; elapsed inactivity never closes one.
struct WorkshopPresenceReducer: Sendable {
    private(set) var agents: [String: WorkshopAgent] = [:]
    private var misses: [String: Int] = [:]

    mutating func reconcile(_ observed: [WorkshopAgent], uncertainProfiles: Set<String>, enabledProfiles: Set<String>) -> [WorkshopAgent] {
        let incoming = Dictionary(observed.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        for (id, old) in agents where incoming[id] == nil {
            guard enabledProfiles.contains(old.profileID) else { agents.removeValue(forKey: id); misses.removeValue(forKey: id); continue }
            if uncertainProfiles.contains(old.profileID) {
                var unknown = old
                unknown.presenceConfirmed = false
                unknown.state = .unavailable
                unknown.activity = "Waiting for a reliable session update"
                agents[id] = unknown
                misses[id] = 0
            } else {
                misses[id, default: 0] += 1
                if misses[id, default: 0] >= 2 { agents.removeValue(forKey: id); misses.removeValue(forKey: id) }
            }
        }
        for (id, agent) in incoming { agents[id] = agent; misses[id] = 0 }
        return agents.values.sorted { ($0.openedAt, $0.id) < ($1.openedAt, $1.id) }
    }
}

struct WorkshopActivityReader: Sendable {
    private(set) var state: WorkshopState = .unavailable
    private(set) var activity = "No activity observed yet"
    private(set) var tool: WorkshopToolKind?
    private(set) var date: Date?
    private(set) var parentSessionID: String?
    private(set) var sessionID: String?
    private(set) var cwd: String?
    private(set) var model: String?
    private(set) var events: [WorkshopEvent] = []
    private var pendingTools: [(id: String, name: String)] = []
    private var sequence = 0

    mutating func consume(_ data: Data, source: UsageSource) {
        guard let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = row["type"] as? String else { return }
        let timestamp = (row["timestamp"] as? String).flatMap(JSONLParser.epoch(fromISO8601:)).map(Date.init(timeIntervalSince1970:))
        if source == .codex {
            let p = row["payload"] as? [String: Any] ?? [:]
            let kind = p["type"] as? String ?? ""
            if type == "session_meta" {
                sessionID = p["id"] as? String ?? p["session_id"] as? String
                cwd = p["cwd"] as? String
                let origin = p["source"] as? [String: Any]
                let subagent = origin?["subagent"] as? [String: Any]
                let spawn = subagent?["spawn"] as? [String: Any]
                parentSessionID = p["parent_thread_id"] as? String ?? spawn?["parent_thread_id"] as? String
            } else if type == "turn_context" {
                model = p["model"] as? String ?? model
                cwd = p["cwd"] as? String ?? cwd
            } else if type == "event_msg" {
                switch kind {
                case "task_started", "turn_started", "user_message":
                    pendingTools.removeAll(); transition(.working, "Working on the current turn", at: timestamp)
                case "task_complete", "turn_complete":
                    pendingTools.removeAll(); transition(.completed, "Turn finished · session still open", at: timestamp)
                case "turn_aborted":
                    pendingTools.removeAll(); transition(.interrupted, "Turn interrupted", at: timestamp)
                case "exec_approval_request", "apply_patch_approval_request", "request_user_input":
                    transition(.needsInput, "Waiting for your response", at: timestamp)
                case "context_compacted": transition(.working, "Organizing context", at: timestamp)
                default: break
                }
            } else if type == "response_item" {
                switch kind {
                case "function_call", "custom_tool_call":
                    if let name = p["name"] as? String { startTool(id: p["call_id"] as? String ?? name, name: name, at: timestamp) }
                case "function_call_output", "custom_tool_call_output":
                    finishTool(id: p["call_id"] as? String, at: timestamp)
                case "reasoning", "message":
                    if kind == "reasoning" || p["role"] as? String == "assistant" {
                        if pendingTools.isEmpty { transition(.working, "Working on the current turn", at: timestamp) }
                    }
                default: break
                }
            }
        } else {
            let message = row["message"] as? [String: Any] ?? [:]
            let content = message["content"] as? [[String: Any]] ?? []
            if type == "assistant" {
                model = message["model"] as? String ?? model
                for block in content where block["type"] as? String == "tool_use" {
                    if let name = block["name"] as? String { startTool(id: block["id"] as? String ?? name, name: name, at: timestamp) }
                }
                if message["stop_reason"] as? String == "end_turn" {
                    pendingTools.removeAll(); transition(.completed, "Turn finished · session still open", at: timestamp)
                } else if pendingTools.isEmpty { transition(.working, "Working on the current turn", at: timestamp) }
            } else if type == "user" {
                let results = content.filter { $0["type"] as? String == "tool_result" }
                if !results.isEmpty { for result in results { finishTool(id: result["tool_use_id"] as? String, at: timestamp) } }
                else if row["isMeta"] as? Bool != true { pendingTools.removeAll(); transition(.working, "Working on the current turn", at: timestamp) }
            } else if type == "system", row["subtype"] as? String == "turn_duration" {
                pendingTools.removeAll(); transition(.completed, "Turn finished · session still open", at: timestamp)
            }
        }
    }

    mutating func applyClaudeStatus(_ status: String?, at timestamp: Date?) {
        guard let status else { return }
        // A tool request is more specific than a generic process heartbeat.
        if let timestamp, let date, timestamp < date { return }
        switch status {
        case "idle":
            if state != .completed && state != .interrupted { pendingTools.removeAll(); transition(.idle, "Ready for the next turn", at: timestamp) }
        case "busy", "working":
            if !state.isWorking && state != .needsInput && state != .waitingForAgents { transition(.working, "Working on the current turn", at: timestamp) }
        case "waiting_for_permission", "needs_input", "waiting_for_input": transition(.needsInput, "Waiting for your response", at: timestamp)
        default: break
        }
    }

    private mutating func startTool(id: String, name: String, at timestamp: Date?) {
        pendingTools.removeAll { $0.id == id }
        pendingTools.append((id, name))
        if pendingTools.count > 128 { pendingTools.removeFirst(pendingTools.count - 128) }
        showPendingTool(at: timestamp)
    }
    private mutating func finishTool(id: String?, at timestamp: Date?) {
        // A late result from a completed/aborted turn must not restart the
        // avatar. A tail can also begin with a result whose call wasn't read.
        guard let id, pendingTools.contains(where: { $0.id == id }) else { return }
        pendingTools.removeAll { $0.id == id }
        if pendingTools.isEmpty { transition(.working, "Working on the current turn", at: timestamp) }
        else { showPendingTool(at: timestamp) }
    }
    private mutating func showPendingTool(at timestamp: Date?) {
        let question = pendingTools.last { $0.name.lowercased().contains("request_user_input") || $0.name.lowercased().contains("askuserquestion") }
        guard let tool = question ?? pendingTools.last else { return }
        let name = tool.name.lowercased()
        if name.contains("request_user_input") || name.contains("askuserquestion") {
            transition(.needsInput, "Waiting for your response", at: timestamp)
        } else if name.contains("wait_agent") || name == "wait" {
            transition(.waitingForAgents, "Waiting for delegated work", at: timestamp)
        } else {
            let kind = WorkshopToolKind(toolName: tool.name)
            transition(.usingTool, kind.label, at: timestamp)
            self.tool = kind
        }
    }
    private mutating func transition(_ next: WorkshopState, _ label: String, at timestamp: Date?) {
        let changed = next != state || activity != label
        state = next; activity = label; tool = nil
        if let timestamp { date = timestamp }
        if changed, let timestamp {
            sequence += 1
            events.append(WorkshopEvent(id: "\(timestamp.timeIntervalSince1970)-\(sequence)", date: timestamp, state: next, label: label))
            if events.count > 12 { events.removeFirst(events.count - 12) }
        }
    }
}
