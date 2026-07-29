import Testing
import Foundation
@testable import TkTracker

/// Drives `UpdateChecker.check()` against stubbed responses.
///
/// The `session:` parameter exists for exactly this. Everything here is offline —
/// no test makes a real network request, which is also the point: the feature's
/// promise is that TkTracker is silent unless asked, and that has to be
/// verifiable rather than asserted.
// Serialized: the stub protocol keeps its scripted reply in static storage, so
// tests running in parallel would overwrite each other's response and see
// another test's status code.
@Suite("Update check", .serialized)
struct UpdateCheckTests {
    /// Intercepts every request in an ephemeral session and replies from a script.
    final class StubProtocol: URLProtocol, @unchecked Sendable {
        struct Reply {
            var status: Int
            var body: Data
            var isHTTP: Bool = true
        }
        nonisolated(unsafe) static var reply = Reply(status: 200, body: Data())
        nonisolated(unsafe) static var requestCount = 0

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.requestCount += 1
            let reply = Self.reply
            let response: URLResponse
            if reply.isHTTP {
                response = HTTPURLResponse(
                    url: request.url!, statusCode: reply.status,
                    httpVersion: "HTTP/1.1", headerFields: nil
                )!
            } else {
                response = URLResponse(
                    url: request.url!, mimeType: nil,
                    expectedContentLength: reply.body.count, textEncodingName: nil
                )
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    @MainActor
    private func makeChecker(
        status: Int = 200,
        json: String,
        isHTTP: Bool = true
    ) -> (UpdateChecker, UserDefaults) {
        StubProtocol.reply = .init(status: status, body: Data(json.utf8), isHTTP: isHTTP)
        StubProtocol.requestCount = 0
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: config)
        let defaults = UserDefaults(suiteName: "tktracker-update-\(UUID().uuidString)")!
        return (UpdateChecker(defaults: defaults, session: session), defaults)
    }

    private func release(
        tag: String,
        url: String = "https://github.com/malclement/TkTracker/releases/tag/v9.9.9",
        draft: Bool = false,
        prerelease: Bool = false
    ) -> String {
        """
        {"tag_name":"\(tag)","html_url":"\(url)","body":"notes",
         "draft":\(draft),"prerelease":\(prerelease)}
        """
    }

    @MainActor
    @Test func newerReleaseBecomesAvailable() async {
        let (checker, defaults) = makeChecker(json: release(tag: "v9.9.9"))
        await checker.check()
        guard case .available(let version, let url, let notes) = checker.state else {
            Issue.record("expected .available, got \(checker.state)")
            return
        }
        #expect(version == "9.9.9") // "v" stripped
        #expect(url.host == "github.com")
        #expect(notes == "notes")
        // Only a successful check stamps the throttle.
        #expect(defaults.double(forKey: "lastUpdateCheck") > 0)
    }

    @MainActor
    @Test func sameOrOlderVersionIsUpToDate() async {
        for tag in ["v\(AppVersion.current)", "v0.0.1"] {
            let (checker, _) = makeChecker(json: release(tag: tag))
            await checker.check()
            guard case .upToDate = checker.state else {
                Issue.record("expected .upToDate for \(tag), got \(checker.state)")
                continue
            }
        }
    }

    @MainActor
    @Test func draftsAndPrereleasesAreNotOffered() async {
        for (draft, pre) in [(true, false), (false, true)] {
            let (checker, _) = makeChecker(json: release(tag: "v9.9.9", draft: draft, prerelease: pre))
            await checker.check()
            guard case .upToDate = checker.state else {
                Issue.record("draft=\(draft) prerelease=\(pre) should not be offered, got \(checker.state)")
                continue
            }
        }
    }

    @MainActor
    @Test func untrustedReleaseURLFallsBackToTheKnownGoodPage() async {
        // A response that can name any URL must not be able to send a click to
        // file:// or a custom scheme.
        let (checker, _) = makeChecker(json: release(tag: "v9.9.9", url: "file:///etc/passwd"))
        await checker.check()
        guard case .available(_, let url, _) = checker.state else {
            Issue.record("expected .available, got \(checker.state)")
            return
        }
        #expect(url == UpdateChecker.releasesPage)
        #expect(url.scheme == "https")
    }

    @MainActor
    @Test func errorResponsesFailWithoutStampingTheThrottle() async {
        // A 403 (rate limited) must not consume the daily window, or one blip
        // would silence checks for 24h.
        let (checker, defaults) = makeChecker(status: 403, json: "{}")
        await checker.check()
        guard case .failed = checker.state else {
            Issue.record("expected .failed, got \(checker.state)")
            return
        }
        #expect(defaults.double(forKey: "lastUpdateCheck") == 0)
    }

    @MainActor
    @Test func malformedJSONFailsGracefully() async {
        let (checker, _) = makeChecker(json: "not json at all")
        await checker.check()
        guard case .failed = checker.state else {
            Issue.record("expected .failed, got \(checker.state)")
            return
        }
    }

    @MainActor
    @Test func nonHTTPResponseIsRejected() async {
        let (checker, _) = makeChecker(json: release(tag: "v9.9.9"), isHTTP: false)
        await checker.check()
        guard case .failed = checker.state else {
            Issue.record("expected .failed, got \(checker.state)")
            return
        }
    }

    @MainActor
    @Test func throttleSuppressesASecondCheckWithinADay() async {
        let (checker, defaults) = makeChecker(json: release(tag: "v9.9.9"))
        await checker.checkIfDue(enabled: true)
        #expect(StubProtocol.requestCount == 1)

        await checker.checkIfDue(enabled: true)
        #expect(StubProtocol.requestCount == 1, "second check inside 24h should be suppressed")

        // Older than a day: allowed again.
        defaults.set(Date().timeIntervalSince1970 - 90_000, forKey: "lastUpdateCheck")
        await checker.checkIfDue(enabled: true)
        #expect(StubProtocol.requestCount == 2)
    }

    @MainActor
    @Test func disabledMakesNoRequestAtAll() async {
        // The privacy claim in the README depends on this exact behaviour.
        let (checker, _) = makeChecker(json: release(tag: "v9.9.9"))
        await checker.checkIfDue(enabled: false)
        #expect(StubProtocol.requestCount == 0)
        #expect(checker.state == .idle)
    }

    @MainActor
    @Test func resetClearsASurfacedResult() async {
        let (checker, _) = makeChecker(json: release(tag: "v9.9.9"))
        await checker.check()
        #expect(checker.state != .idle)
        checker.reset()
        #expect(checker.state == .idle)
    }
}
