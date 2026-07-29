import Foundation
import Observation

/// Opt-in release check against the GitHub API.
///
/// TkTracker's privacy claim is that nothing leaves the machine. That has to stay
/// literally true, so this is **off by default** and makes no request of any kind
/// until the user turns it on — no "anonymous" ping, no first-run check. When
/// enabled it fetches one public JSON document at most once a day, sends no
/// identifying information beyond the unavoidable User-Agent, and never
/// downloads or installs anything: it surfaces a version and a link, and the
/// user goes to their browser.
@MainActor
@Observable
final class UpdateChecker {
    enum State: Equatable {
        case idle
        case checking
        case upToDate(checked: Date)
        case available(version: String, url: URL, notes: String?)
        case failed(String)
    }

    private(set) var state: State = .idle

    /// Public releases endpoint — no auth, no cookies.
    private let endpoint = URL(string: "https://api.github.com/repos/malclement/TkTracker/releases/latest")!
    private let minimumInterval: TimeInterval = 86_400
    private let defaults: UserDefaults
    private let session: URLSession

    private var lastCheckKey = "lastUpdateCheck"

    init(defaults: UserDefaults = .standard, session: URLSession? = nil) {
        self.defaults = defaults
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral // no cookies, no cache on disk
            config.httpShouldSetCookies = false
            config.httpCookieAcceptPolicy = .never
            config.urlCache = nil
            config.timeoutIntervalForRequest = 15
            self.session = URLSession(configuration: config)
        }
    }

    var lastChecked: Date? {
        let stamp = defaults.double(forKey: lastCheckKey)
        return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
    }

    /// Called on launch and once a day while running. Does nothing unless the
    /// user has opted in and a day has passed.
    func checkIfDue(enabled: Bool) async {
        guard enabled else { return }
        if let last = lastChecked, Date().timeIntervalSince(last) < minimumInterval { return }
        await check()
    }

    /// Explicit "Check now". Always performs the request.
    func check() async {
        guard state != .checking else { return }
        state = .checking
        Diagnostics.update.info("checking for updates")

        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("TkTracker/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw UpdateError.message("no response")
            }
            guard http.statusCode == 200 else {
                throw UpdateError.message("GitHub returned \(http.statusCode)")
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            defaults.set(Date().timeIntervalSince1970, forKey: lastCheckKey)

            let latest = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            if AppVersion.isNewer(latest, than: AppVersion.current), !release.draft, !release.prerelease {
                let url = URL(string: release.htmlUrl) ?? endpoint
                state = .available(version: latest, url: url, notes: release.body)
                Diagnostics.update.notice("update available: \(latest, privacy: .public)")
            } else {
                state = .upToDate(checked: Date())
                Diagnostics.update.info("up to date")
            }
        } catch {
            state = .failed(error.localizedDescription)
            Diagnostics.update.error("update check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Clears any surfaced result — used when the user turns the setting off, so
    /// no stale banner survives opting out.
    func reset() {
        state = .idle
    }

    private enum UpdateError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self {
            case .message(let text): return text
            }
        }
    }

    private struct Release: Decodable {
        let tagName: String
        let htmlUrl: String
        let body: String?
        let draft: Bool
        let prerelease: Bool

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlUrl = "html_url"
            case body, draft, prerelease
        }
    }
}
