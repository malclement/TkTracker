import Foundation
import Testing
import simd
import Darwin
@testable import TkTracker

@Suite("Floating workshops")
struct WorkshopTests {
    private let now = Date(timeIntervalSince1970: 1_788_890_400)

    private func agent(_ id: String, parent: String? = nil, profile: String = "account", state: WorkshopState = .working) -> WorkshopAgent {
        WorkshopAgent(id: WorkshopAgent.key(profile: profile, source: .codex, session: id), sessionID: id, profileID: profile,
            source: .codex, parentSessionID: parent, projectPath: "/project", title: id, state: state,
            activity: state.label, openedAt: now)
    }
    private func row(_ type: String, _ payload: [String: Any], timestamp: String = "2026-09-08T20:00:00Z") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["timestamp": timestamp, "type": type, "payload": payload])
    }

    @Test func inactivityNeverClosesAnIsland() {
        var reducer = WorkshopPresenceReducer()
        let a = agent("root", state: .idle)
        for _ in 0..<100 {
            #expect(reducer.reconcile([a], uncertainProfiles: [], enabledProfiles: ["account"]).count == 1)
        }
        #expect(reducer.reconcile([], uncertainProfiles: [], enabledProfiles: ["account"]).count == 1)
        #expect(reducer.reconcile([], uncertainProfiles: [], enabledProfiles: ["account"]).isEmpty)
    }

    @Test func failedObservationPreservesIslandsAndResetsClosure() {
        var reducer = WorkshopPresenceReducer()
        let a = agent("root")
        _ = reducer.reconcile([a], uncertainProfiles: [], enabledProfiles: ["account"])
        _ = reducer.reconcile([], uncertainProfiles: [], enabledProfiles: ["account"])
        let unavailable = reducer.reconcile([], uncertainProfiles: ["account"], enabledProfiles: ["account"])
        #expect(unavailable.first?.state == .unavailable)
        #expect(unavailable.first?.presenceConfirmed == false)
        #expect(reducer.reconcile([], uncertainProfiles: [], enabledProfiles: ["account"]).count == 1)
        #expect(reducer.reconcile([a], uncertainProfiles: [], enabledProfiles: ["account"]).first?.state == .working)
        #expect(reducer.reconcile([], uncertainProfiles: ["account"], enabledProfiles: []).isEmpty)
    }

    @Test func nestedSubagentsAndAccountsStaySeparate() {
        let forest = WorkshopIsland.group([agent("a"), agent("b", parent: "a"), agent("c", parent: "b"), agent("a", profile: "other")])
        #expect(forest.count == 2)
        #expect(forest.first { $0.lead.profileID == "account" }?.subagents.count == 2)
        #expect(forest.flatMap(\.agents).count == 4)
    }

    @Test func malformedTreesRemainVisibleWithoutDuplicates() {
        let forest = WorkshopIsland.group([agent("a", parent: "b"), agent("b", parent: "a"), agent("c", parent: "missing"), agent("self", parent: "self")])
        #expect(forest.count == 3)
        #expect(Set(forest.flatMap(\.agents).map(\.id)).count == 4)
    }

    @Test func completedTurnIsDistinctFromClosureAndCanResume() throws {
        var reader = WorkshopActivityReader()
        reader.consume(try row("event_msg", ["type": "task_started"]), source: .codex)
        #expect(reader.state == .working)
        reader.consume(try row("event_msg", ["type": "task_complete"]), source: .codex)
        #expect(reader.state == .completed)
        reader.consume(try row("event_msg", ["type": "task_started"]), source: .codex)
        #expect(reader.state == .working)
        reader.consume(try row("event_msg", ["type": "turn_aborted"]), source: .codex)
        #expect(reader.state == .interrupted)
    }

    @Test func explicitInputAndConcurrentTools() throws {
        var reader = WorkshopActivityReader()
        reader.consume(try row("response_item", ["type": "function_call", "name": "exec_command", "call_id": "exec"]), source: .codex)
        reader.consume(try row("response_item", ["type": "function_call", "name": "request_user_input", "call_id": "question"]), source: .codex)
        #expect(reader.state == .needsInput)
        reader.consume(try row("response_item", ["type": "function_call", "name": "read_file", "call_id": "read"]), source: .codex)
        #expect(reader.state == .needsInput)
        reader.consume(try row("response_item", ["type": "function_call_output", "call_id": "exec", "output": "private tool output"]), source: .codex)
        #expect(reader.state == .needsInput)
        reader.consume(try row("response_item", ["type": "function_call_output", "call_id": "question"]), source: .codex)
        #expect(reader.state == .usingTool)
        reader.consume(try row("response_item", ["type": "function_call_output", "call_id": "read"]), source: .codex)
        #expect(reader.state == .working)
        #expect(reader.events.allSatisfy { !$0.label.contains("private") })
    }

    @Test func metadataSupportsBothCodexParentFormats() throws {
        var current = WorkshopActivityReader()
        current.consume(try row("session_meta", ["id": "child", "parent_thread_id": "root", "cwd": "/project"]), source: .codex)
        #expect(current.parentSessionID == "root")
        var legacy = WorkshopActivityReader()
        legacy.consume(try row("session_meta", ["id": "child", "source": ["subagent": ["spawn": ["parent_thread_id": "root"]]]]), source: .codex)
        #expect(legacy.parentSessionID == "root")
    }

    @Test func waitingForAToolIsDistinctFromWaitingForAgents() throws {
        var reader = WorkshopActivityReader()
        reader.consume(try row("response_item", ["type": "function_call", "name": "functions.wait", "call_id": "tool-wait"]), source: .codex)
        #expect(reader.state == .usingTool)
        reader.consume(try row("response_item", ["type": "function_call", "name": "collaboration.wait_agent", "call_id": "agent-wait"]), source: .codex)
        #expect(reader.state == .waitingForAgents)
    }

    @Test func claudeInputAndCompletionAreExplicit() throws {
        var reader = WorkshopActivityReader()
        let tool: [String: Any] = ["type": "assistant", "timestamp": "2026-09-08T20:00:00Z", "message": ["content": [["type": "tool_use", "name": "AskUserQuestion", "id": "q"]]]]
        reader.consume(try JSONSerialization.data(withJSONObject: tool), source: .claude)
        #expect(reader.state == .needsInput)
        reader.applyClaudeStatus("busy", at: Date.distantFuture)
        #expect(reader.state == .needsInput)
        let finished: [String: Any] = ["type": "assistant", "timestamp": "2026-09-08T20:01:00Z", "message": ["content": [], "stop_reason": "end_turn"]]
        reader.consume(try JSONSerialization.data(withJSONObject: finished), source: .claude)
        #expect(reader.state == .completed)
        reader.applyClaudeStatus("idle", at: Date.distantFuture)
        #expect(reader.state == .completed)
    }

    @Test func claudeProcessStartUsesUTCWithoutATimezoneSuffix() throws {
        let parsed = try #require(WorkshopProcessProbe.claudeProcessStart("Mon Sep 14 13:31:57 2026"))
        #expect(parsed.timeIntervalSince1970 == JSONLParser.epoch(fromISO8601: "2026-09-14T13:31:57Z"))
        #expect(WorkshopProcessProbe.claudeProcessStart("invalid") == nil)
    }

    @Test func claudePresenceAcceptsUTCStartAndRejectsReusedPID() throws {
        var info = proc_bsdinfo()
        #expect(proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) > 0)
        let actual = Date(timeIntervalSince1970: Double(info.pbi_start_tvsec))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        #expect(WorkshopProcessProbe.presence(pid: getpid(), startedAt: Date(), processStart: formatter.string(from: actual)) == true)
        #expect(WorkshopProcessProbe.presence(pid: getpid(), startedAt: Date(), processStart: formatter.string(from: actual.addingTimeInterval(-3600))) == false)
    }

    @Test func claudeSessionFindsTranscriptBeforeUsageScanAndCloses() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tktracker-claude-workshops-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = root.appendingPathComponent("projects")
        let metadata = root.appendingPathComponent("sessions")
        let cwd = "/Users/test/my_project.v2/é😀"
        let project = projects.appendingPathComponent(CodexParser.encodeProjectDir(cwd))
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased()
        let session = metadata.appendingPathComponent("test.json")
        try JSONSerialization.data(withJSONObject: ["pid": getpid(), "sessionId": id, "cwd": cwd,
            "startedAt": Date().timeIntervalSince1970 * 1000, "pidDomain": "darwin"])
            .write(to: session)
        let transcript = project.appendingPathComponent(id + ".jsonl")
        let event: [String: Any] = ["type": "assistant", "timestamp": "2026-09-14T13:30:00Z",
            "message": ["model": "claude-opus-4-8", "stop_reason": "end_turn", "content": []]]
        var data = try JSONSerialization.data(withJSONObject: event)
        data.append(10)
        try data.write(to: transcript)
        let profile = SourceProfile(id: "test", name: "Test", source: .claude, rootPath: projects.path)
        let monitor = WorkshopMonitor()
        let snapshot = await monitor.snapshot(profiles: [profile], digests: [], keepsTitles: false)
        #expect(snapshot.agents.count == 1)
        #expect(snapshot.agents.first?.sessionID == id)
        #expect(snapshot.agents.first?.state == .completed)
        #expect(snapshot.agents.first?.model == "claude-opus-4-8")
        #expect(!snapshot.hasUncertainty)
        try FileManager.default.removeItem(at: session)
        let firstMiss = await monitor.snapshot(profiles: [profile], digests: [], keepsTitles: false)
        #expect(firstMiss.agents.count == 1)
        let closed = await monitor.snapshot(profiles: [profile], digests: [], keepsTitles: false)
        #expect(closed.agents.isEmpty)
    }

    @Test func unknownAndMalformedEventsDoNotInventActivity() throws {
        var reader = WorkshopActivityReader()
        reader.consume(Data("not json".utf8), source: .codex)
        reader.consume(try row("event_msg", ["type": "future_event"]), source: .codex)
        #expect(reader.state == .unavailable)
        #expect(reader.events.isEmpty)
    }

    @Test func lateToolResultsDoNotRestartFinishedAgents() throws {
        var reader = WorkshopActivityReader()
        reader.consume(try row("response_item", ["type": "function_call", "name": "exec_command", "call_id": "old"]), source: .codex)
        reader.consume(try row("event_msg", ["type": "task_complete"]), source: .codex)
        reader.consume(try row("response_item", ["type": "function_call_output", "call_id": "old"]), source: .codex)
        #expect(reader.state == .completed)
        reader.consume(try row("event_msg", ["type": "turn_aborted"]), source: .codex)
        reader.consume(try row("response_item", ["type": "function_call_output", "call_id": "unknown"]), source: .codex)
        #expect(reader.state == .interrupted)
    }

    @Test func incrementalReadKeepsPartialLinesAndRespectsPrivacy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tktracker-workshops-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString.lowercased()
        let path = root.appendingPathComponent("rollout-\(id).jsonl")
        var data = try row("session_meta", ["id": id, "cwd": "/project", "parent_thread_id": "root"])
        data.append(10)
        let start = try row("event_msg", ["type": "task_started"])
        data.append(start.prefix(start.count / 2))
        try data.write(to: path)
        let canonical = ScanCore.canonicalPath(path)
        let monitor = WorkshopMonitor(processProbe: { .init(codexTranscripts: [canonical]) })
        let profile = SourceProfile(id: "test", name: "Test", source: .codex, rootPath: root.path)
        var digest = FileDigest(path: canonical, source: .codex, sessionId: id, projectDir: "project", aiTitle: "Sensitive title", profileId: "test")
        var snapshot = await monitor.snapshot(profiles: [profile], digests: [digest], keepsTitles: false, now: now)
        #expect(snapshot.agents.count == 1)
        #expect(snapshot.agents.first?.state == .unavailable)
        #expect(snapshot.agents.first?.title.contains("Sensitive") == false)
        #expect(snapshot.agents.first?.parentSessionID == "root")
        let file = try FileHandle(forWritingTo: path)
        defer { try? file.close() }
        try file.seekToEnd()
        var rest = Data(start.suffix(start.count - start.count / 2)); rest.append(10)
        try file.write(contentsOf: rest)
        snapshot = await monitor.snapshot(profiles: [profile], digests: [digest], keepsTitles: true, now: now.addingTimeInterval(2))
        #expect(snapshot.agents.first?.state == .working)
        #expect(snapshot.agents.first?.title == "Sensitive title")
        #expect(snapshot.agents.first?.openedAt == now)
        // Truncating the same file resets the activity cache rather than leaving
        // the previous turn permanently active.
        var replacement = try row("event_msg", ["type": "task_complete"]); replacement.append(10)
        try file.truncate(atOffset: 0); try file.seek(toOffset: 0); try file.write(contentsOf: replacement)
        digest.aiTitle = nil
        snapshot = await monitor.snapshot(profiles: [profile], digests: [digest], keepsTitles: true)
        #expect(snapshot.agents.first?.state == .completed)
    }

    @Test func unrelatedRootsNeverBecomeIslands() async {
        let monitor = WorkshopMonitor(processProbe: { .init(codexTranscripts: ["/different/rollout-00000000-0000-0000-0000-000000000000.jsonl"]) })
        let profile = SourceProfile(id: "test", name: "Test", source: .codex, rootPath: "/configured")
        let snapshot = await monitor.snapshot(profiles: [profile], digests: [], keepsTitles: true)
        #expect(snapshot.agents.isEmpty)
    }

    @Test func processIdentityRejectsReusedPID() {
        let actual = WorkshopProcessProbe.presence(pid: getpid(), startedAt: Date(), processStart: nil)
        #expect(actual == true)
        #expect(WorkshopProcessProbe.presence(pid: getpid(), startedAt: Date(), processStart: "Mon Jan 1 00:00:00 2001") == false)
    }
}
