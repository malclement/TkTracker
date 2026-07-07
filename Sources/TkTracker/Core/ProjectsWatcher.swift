import Foundation
import CoreServices

/// FSEvents watcher over ~/.claude/projects. Fires a coalesced callback on any
/// change; the engine stats all files anyway, so per-path bookkeeping is skipped.
final class ProjectsWatcher {
    private let path: String
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "tktracker.fsevents", qos: .utility)
    private var stream: FSEventStreamRef?

    init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
    }

    func start() {
        guard stream == nil else { return }
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
            Unmanaged<ProjectsWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.4, // latency: coalesce bursts while an assistant turn streams
            FSEventStreamCreateFlags(flags)
        ) else { return }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
