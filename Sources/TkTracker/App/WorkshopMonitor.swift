import Foundation
import Darwin
import Observation

/// Read-only observation of this user's local processes. No hooks, configuration
/// changes, new agent servers, network requests, or transcript writes.
enum WorkshopProcessProbe {
    struct Result: Sendable {
        var codexTranscripts: Set<String> = []
        var codexUncertain = false
    }

    static func sample() -> Result {
        var result = Result()
        let required = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), nil, 0)
        guard required > 0 else { result.codexUncertain = true; return result }
        var ids = [Int32](repeating: 0, count: Int(required) / MemoryLayout<Int32>.stride + 256)
        let capacity = Int32(ids.count * MemoryLayout<Int32>.stride)
        let bytes = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), &ids, capacity)
        guard bytes > 0 && bytes < capacity else { result.codexUncertain = true; return result }
        for pid in ids.prefix(Int(bytes) / MemoryLayout<Int32>.stride) where pid > 0 {
            var executable = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &executable, UInt32(executable.count)) > 0 else { continue }
            guard URL(fileURLWithPath: String(cString: executable)).lastPathComponent.lowercased() == "codex" else { continue }
            let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard needed > 0 else {
                if kill(pid, 0) == 0 || errno == EPERM { result.codexUncertain = true }
                continue
            }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / MemoryLayout<proc_fdinfo>.stride + 128)
            let fdCapacity = Int32(fds.count * MemoryLayout<proc_fdinfo>.stride)
            let fdBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, fdCapacity)
            guard fdBytes > 0 && fdBytes < fdCapacity else { result.codexUncertain = true; continue }
            for fd in fds.prefix(Int(fdBytes) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == PROX_FDTYPE_VNODE {
                var info = vnode_fdinfowithpath()
                let read = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, Int32(MemoryLayout.size(ofValue: info)))
                guard read > 0 else {
                    if errno == EPERM || errno == EACCES { result.codexUncertain = true }
                    continue
                }
                let path = withUnsafePointer(to: &info.pvip.vip_path) {
                    String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
                }
                // History reads also open rollout files. Only a retained writer
                // descriptor establishes a loaded session.
                if path.hasSuffix(".jsonl") && info.pfi.fi_openflags & UInt32(FWRITE) != 0 { result.codexTranscripts.insert(path) }
            }
        }
        return result
    }

    /// Verify the process start, not just PID existence: metadata can survive a
    /// crash and macOS can reuse its PID for an unrelated process.
    static func presence(pid: Int32, startedAt: Date, processStart: String?) -> Bool? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) > 0 else {
            return errno == ESRCH ? false : nil
        }
        guard info.pbi_uid == getuid(), info.pbi_status != SZOMB else { return false }
        let actual = Date(timeIntervalSince1970: Double(info.pbi_start_tvsec))
        if let processStart {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
            if let expected = formatter.date(from: processStart) { return abs(actual.timeIntervalSince(expected)) < 2 }
        }
        return actual <= startedAt.addingTimeInterval(2)
    }
}

actor WorkshopMonitor {
    struct Snapshot: Sendable {
        var agents: [WorkshopAgent]
        var hasUncertainty: Bool
        var observedAt: Date
    }
    private struct Tail {
        var offset: UInt64 = 0
        var identity: UInt64 = 0
        var pending = Data()
        var reader = WorkshopActivityReader()
    }
    private var tails: [String: Tail] = [:]
    private var opened: [String: Date] = [:]
    private var presence = WorkshopPresenceReducer()
    private let processProbe: @Sendable () -> WorkshopProcessProbe.Result

    init(processProbe: @escaping @Sendable () -> WorkshopProcessProbe.Result = { WorkshopProcessProbe.sample() }) {
        self.processProbe = processProbe
    }

    func snapshot(profiles: [SourceProfile], digests: [FileDigest], keepsTitles: Bool, now: Date = Date()) -> Snapshot {
        let profiles = profiles.filter(\.enabled)
        let probe = profiles.contains { $0.source == .codex } ? processProbe() : .init()
        var observed: [WorkshopAgent] = []
        var uncertain = Set<String>()
        var usedPaths = Set<String>()
        let lookup = Dictionary(digests.map { (WorkshopAgent.key(profile: $0.profileId ?? $0.source.rawValue, source: $0.source, session: $0.sessionId), $0) }, uniquingKeysWith: { a, b in a.mtime >= b.mtime ? a : b })

        for profile in profiles {
            let root = ScanCore.canonicalPath(profile.root)
            if profile.source == .codex {
                if probe.codexUncertain { uncertain.insert(profile.id) }
                for path in probe.codexTranscripts.sorted() where path.hasPrefix(root + "/") {
                    usedPaths.insert(path)
                    let activity = read(path: path, source: .codex)
                    guard let id = activity?.sessionID ?? Self.sessionID(from: path) else { uncertain.insert(profile.id); continue }
                    let key = WorkshopAgent.key(profile: profile.id, source: .codex, session: id)
                    let digest = lookup[key]
                    let first = opened[key] ?? now
                    opened[key] = first
                    observed.append(makeAgent(id: id, profile: profile, digest: digest, reader: activity,
                        path: path, cwd: digest?.cwd ?? activity?.cwd ?? "", openedAt: first, keepsTitles: keepsTitles))
                }
            } else {
                let metadataRoot = profile.root.deletingLastPathComponent().appendingPathComponent("sessions")
                guard let files = try? FileManager.default.contentsOfDirectory(at: metadataRoot, includingPropertiesForKeys: nil) else {
                    uncertain.insert(profile.id); continue
                }
                for file in files where file.pathExtension == "json" {
                    guard let data = try? Data(contentsOf: file), data.count < 64 * 1024,
                          let meta = try? JSONDecoder().decode(ClaudeSession.self, from: data) else { uncertain.insert(profile.id); continue }
                    // Foreign/remote PID namespaces cannot establish local presence.
                    guard meta.pidDomain == nil || meta.pidDomain == "darwin" else { continue }
                    guard let alive = WorkshopProcessProbe.presence(pid: meta.pid, startedAt: meta.startDate, processStart: meta.procStart) else {
                        uncertain.insert(profile.id); continue
                    }
                    guard alive else { continue }
                    let key = WorkshopAgent.key(profile: profile.id, source: .claude, session: meta.sessionId)
                    let digest = lookup[key]
                    let candidate = digest?.path ?? profile.root.appendingPathComponent(meta.cwd.replacingOccurrences(of: "/", with: "-")).appendingPathComponent(meta.sessionId + ".jsonl").path
                    // Keep configured accounts isolated even when a metadata directory is shared.
                    guard ScanCore.canonicalPath(URL(fileURLWithPath: candidate)).hasPrefix(root + "/") else { continue }
                    usedPaths.insert(candidate)
                    var reader = read(path: candidate, source: .claude) ?? WorkshopActivityReader()
                    reader.applyClaudeStatus(meta.status, at: meta.statusUpdatedAt.map { Date(timeIntervalSince1970: $0 / 1000) })
                    observed.append(makeAgent(id: meta.sessionId, profile: profile, digest: digest, reader: reader,
                        path: digest?.path, cwd: meta.cwd, openedAt: meta.startDate, keepsTitles: keepsTitles))

                    // Subagents are transcript-backed within the currently loaded
                    // parent. Old runs are excluded when a session is resumed.
                    var parentIDs: Set<String> = [meta.sessionId]
                    let children = digests.filter { $0.source == .claude && ($0.profileId ?? "claude") == profile.id && !$0.missing && $0.parentSessionId != nil && ($0.lastTs ?? $0.mtime) >= meta.startDate.timeIntervalSince1970 }
                    for _ in 0..<32 {
                        var added = false
                        for child in children where !parentIDs.contains(child.sessionId) && child.parentSessionId.map({ parentIDs.contains($0) }) == true {
                            parentIDs.insert(child.sessionId); added = true
                            usedPaths.insert(child.path)
                            let activity = read(path: child.path, source: .claude)
                            observed.append(makeAgent(id: child.sessionId, profile: profile, digest: child, reader: activity,
                                path: child.path, cwd: child.cwd ?? meta.cwd, openedAt: Date(timeIntervalSince1970: child.firstTs ?? meta.startDate.timeIntervalSince1970), keepsTitles: keepsTitles))
                        }
                        if !added { break }
                    }
                }
            }
        }
        let result = presence.reconcile(observed, uncertainProfiles: uncertain, enabledProfiles: Set(profiles.map(\.id)))
        let activeIDs = Set(result.map(\.id))
        opened = opened.filter { activeIDs.contains($0.key) }
        let retainedPaths = Set(result.compactMap(\.digestPath))
        tails = tails.filter { usedPaths.contains($0.key) || retainedPaths.contains($0.key) }
        return Snapshot(agents: result, hasUncertainty: !uncertain.isEmpty, observedAt: now)
    }

    private func makeAgent(id: String, profile: SourceProfile, digest: FileDigest?, reader: WorkshopActivityReader?, path: String?, cwd: String, openedAt: Date, keepsTitles: Bool) -> WorkshopAgent {
        WorkshopAgent(id: WorkshopAgent.key(profile: profile.id, source: profile.source, session: id), sessionID: id,
            profileID: profile.id, source: profile.source, parentSessionID: reader?.parentSessionID ?? digest?.parentSessionId,
            projectPath: cwd, title: keepsTitles ? (digest?.title ?? "Session \(id.prefix(8))") : "Session \(id.prefix(8))",
            model: reader?.model ?? digest?.lastModel, digestPath: path, state: reader?.state ?? .unavailable,
            activity: reader?.activity ?? "Waiting for activity details", lastActivity: reader?.date,
            openedAt: openedAt, events: reader?.events ?? [])
    }

    private func read(path: String, source: UsageSource) -> WorkshopActivityReader? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let file = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? file.close() }
        let identity = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        var tail = tails[path] ?? Tail()
        if size < tail.offset || identity != tail.identity { tail = Tail(); tail.identity = identity }
        do {
            if tail.offset == 0 {
                // Metadata lives on the first line, even when the activity tail is large.
                let header = try file.read(upToCount: 1024 * 1024) ?? Data()
                if let newline = header.firstIndex(of: 10) { tail.reader.consume(Data(header[..<newline]), source: source) }
                let start = size > 1024 * 1024 ? size - 1024 * 1024 : 0
                try file.seek(toOffset: start)
                tail.offset = start
                if start > 0 {
                    let chunk = try file.read(upToCount: 1024 * 1024) ?? Data()
                    tail.offset += UInt64(chunk.count)
                    if let newline = chunk.firstIndex(of: 10) { tail.pending = Data(chunk[chunk.index(after: newline)...]) }
                }
            }
            try file.seek(toOffset: tail.offset)
            let chunk = try file.read(upToCount: 2 * 1024 * 1024) ?? Data()
            tail.offset += UInt64(chunk.count)
            tail.pending.append(chunk)
            while let newline = tail.pending.firstIndex(of: 10) {
                tail.reader.consume(Data(tail.pending[..<newline]), source: source)
                tail.pending.removeSubrange(...newline)
            }
            // A huge tool output must not grow the ephemeral cache without bound.
            if tail.pending.count > 2 * 1024 * 1024 { tail.pending.removeAll() }
            tails[path] = tail
            return tail.reader
        } catch { return nil }
    }

    static func sessionID(from path: String) -> String? {
        let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let suffix = String(stem.suffix(36))
        return UUID(uuidString: suffix) == nil ? nil : suffix
    }
    private struct ClaudeSession: Decodable {
        var pid: Int32
        var sessionId: String
        var cwd: String
        var startedAt: Double
        var procStart: String?
        var pidDomain: String?
        var status: String?
        var statusUpdatedAt: Double?
        var startDate: Date { Date(timeIntervalSince1970: startedAt / 1000) }
    }
}

@MainActor @Observable
final class WorkshopStore {
    private(set) var agents: [WorkshopAgent] = []
    private(set) var hasUncertainty = false
    private(set) var hasLoaded = false
    private(set) var observedAt: Date?
    private let monitor = WorkshopMonitor()

    func refresh(profiles: [SourceProfile], digests: [FileDigest], keepsTitles: Bool) async {
        let snapshot = await monitor.snapshot(profiles: profiles, digests: digests, keepsTitles: keepsTitles)
        guard !Task.isCancelled else { return }
        agents = snapshot.agents
        hasUncertainty = snapshot.hasUncertainty
        observedAt = snapshot.observedAt
        hasLoaded = true
    }
}
