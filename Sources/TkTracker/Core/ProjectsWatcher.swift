import Foundation
import CoreServices

/// FSEvents watcher over a session directory (`~/.claude/projects`,
/// `~/.codex/sessions`). Fires a coalesced callback on any change; the engine
/// stats all files anyway, so per-path bookkeeping is skipped.
///
/// The directory may not exist yet — someone can install TkTracker before Codex,
/// or before ever running Claude Code. `FSEventStreamCreate` accepts a missing
/// path and returns a stream that simply never fires, which used to leave live
/// updates permanently dead for that source until the app was relaunched (only
/// the five-minute polling net caught it). So when the target is absent the
/// watcher falls back to the nearest existing ancestor and promotes itself to
/// the real directory as soon as it appears.
final class ProjectsWatcher {
    private let path: String
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "tktracker.fsevents", qos: .utility)
    private var stream: FSEventStreamRef?
    /// The path actually being watched — the target, or an ancestor standing in
    /// for it until it exists.
    private var watchedPath: String?

    init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
    }

    func start() {
        guard stream == nil else { return }
        let target = FileManager.default.fileExists(atPath: path) ? path : Self.nearestExistingAncestor(of: path)
        guard let target else {
            Diagnostics.app.error("no watchable ancestor for \(self.path, privacy: .public)")
            return
        }
        if target != path {
            Diagnostics.app.notice("session directory absent; watching ancestor until it appears")
        }
        arm(on: target)
    }

    private func arm(on target: String) {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<ProjectsWatcher>.fromOpaque(info).takeUnretainedValue().handleEvent()
        }
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [target] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.4, // latency: coalesce bursts while an assistant turn streams
            FSEventStreamCreateFlags(flags)
        ) else { return }
        stream = created
        watchedPath = target
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
    }

    /// Runs on `queue`.
    private func handleEvent() {
        // Standing in for a missing directory: if it now exists, move the watch
        // onto it so we stop seeing the ancestor's unrelated traffic.
        if watchedPath != path, FileManager.default.fileExists(atPath: path) {
            Diagnostics.app.notice("session directory appeared; watching it directly")
            tearDown()
            arm(on: path)
        }
        onChange()
    }

    func stop() {
        tearDown()
    }

    private func tearDown() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        watchedPath = nil
    }

    /// Deepest existing directory at or above `path`. Nil only if even the root
    /// is unreachable.
    static func nearestExistingAncestor(of path: String) -> String? {
        var candidate = URL(fileURLWithPath: path, isDirectory: true)
        let fm = FileManager.default
        while candidate.path != "/" {
            candidate = candidate.deletingLastPathComponent()
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return candidate.path
            }
        }
        return fm.fileExists(atPath: "/") ? "/" : nil
    }

    deinit { tearDown() }
}
