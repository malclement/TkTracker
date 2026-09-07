import Foundation

/// Starts the installed CLI only after the user opts in. No credentials are
/// read by TkTracker: the CLI owns authentication and the account request.
enum CodexQuotaClient {
    enum Failure: LocalizedError {
        case missingCLI, timeout, invalidReply, server(String)
        var errorDescription: String? {
            switch self {
            case .missingCLI: return "Choose the Codex executable in Settings."
            case .timeout: return "Codex did not return quotas within 15 seconds."
            case .invalidReply: return "Codex returned no supported quota windows."
            case .server(let message): return message
            }
        }
    }

    static func fetch(executable: URL, configRoot: URL, timeout: TimeInterval = 15) async throws -> QuotaSnapshot {
        try await Task.detached(priority: .utility) { try run(executable: executable, configRoot: configRoot, timeout: timeout) }.value
    }

    private static func run(executable: URL, configRoot: URL, timeout: TimeInterval) throws -> QuotaSnapshot {
            guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw Failure.missingCLI }
            let process = Process()
            process.executableURL = executable
            process.arguments = ["app-server"]
            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_HOME"] = configRoot.path
            process.environment = environment
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            let reply = ReplyBuffer()
            output.fileHandleForReading.readabilityHandler = { handle in
                reply.append(handle.availableData)
            }
            let terminated = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in terminated.signal() }
            try process.run()
            defer {
                output.fileHandleForReading.readabilityHandler = nil
                try? input.fileHandleForWriting.close()
                if process.isRunning {
                    process.terminate()
                    if terminated.wait(timeout: .now() + 1) == .timedOut, process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
                try? output.fileHandleForReading.close()
            }
            func send(_ message: [String: Any]) throws {
                var data = try JSONSerialization.data(withJSONObject: message)
                data.append(0x0A)
                try input.fileHandleForWriting.write(contentsOf: data)
            }
            try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "tktracker", "version": AppVersion.current]]])
            guard let initialized = reply.waitFor(id: 1, timeout: timeout) else { throw Failure.timeout }
            if let error = initialized["error"] as? [String: Any] { throw Failure.server(error["message"] as? String ?? "Codex initialization failed.") }
            try send(["method": "initialized"])
            try send(["id": 2, "method": "account/rateLimits/read"])
            guard let object = reply.waitFor(id: 2, timeout: timeout) else { throw Failure.timeout }
            if let error = object["error"] as? [String: Any] { throw Failure.server(error["message"] as? String ?? "Codex quota request failed.") }
            guard let result = object["result"] as? [String: Any] else { throw Failure.invalidReply }
            let snapshot = QuotaSnapshot.parse(result, at: Date(), origin: "Codex account")
            guard !snapshot.windows.isEmpty else { throw Failure.invalidReply }
            return snapshot
    }

    private final class ReplyBuffer: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var buffer = Data()
        private var replies: [Int: [String: Any]] = [:]
        private var finished = false
        func finish() { lock.lock(); finished = true; lock.unlock(); done.signal() }
        func waitFor(id: Int, timeout: TimeInterval) -> [String: Any]? {
            let deadline = DispatchTime.now() + timeout
            while true {
                lock.lock()
                let value = replies[id], ended = finished
                lock.unlock()
                if let value { return value }
                if ended || done.wait(timeout: deadline) == .timedOut { return nil }
            }
        }
        func append(_ data: Data) {
            lock.lock(); defer { lock.unlock() }
            guard !finished else { return }
            guard !data.isEmpty, buffer.count + data.count < 8 << 20 else { finished = true; done.signal(); return }
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                if let raw = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                   let id = raw["id"] as? Int, id == 1 || id == 2 {
                    replies[id] = raw; done.signal()
                }
                buffer.removeSubrange(...newline)
            }
        }
    }
}
