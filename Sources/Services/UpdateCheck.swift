import AppKit
import Observation

/// The public release manifest the site serves at `/release.json`. Same shape
/// `site/tests/site.test.mjs` enforces; an unreadable field is not guessed.
struct ReleaseManifest: Decodable, Equatable {
    var version: String
    var available: Bool
    var url: String?
    var sha256: String?
    var notarized: Bool?
}

/// Numeric major.minor.patch ordering. A string compare would rank 0.1.9 above
/// 0.1.10, which is the same trap the installer's build-number comparison avoids.
enum AppVersion {
    static func components(_ text: String) -> [Int]? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var result: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = Int(part) else { return nil }
            result.append(value)
        }
        return result
    }
    /// False whenever either side is not a release version; a development build is never behind.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let a = components(candidate), let b = components(current) else { return false }
        return b.lexicographicallyPrecedes(a)
    }
}

enum UpdateCheckError: Error { case status(Int), notHTTP }

/// One optional read of the public release manifest when the app starts.
/// Sends no usage, account, or version; downloads stay a manual browser action.
/// Previews and render modes never construct a live check.
@Observable final class UpdateCheck {
    enum Outcome: Equatable {
        case current(String)
        case available(ReleaseManifest)
        case failed(String)
    }
    static let manifestURL = URL(string: "https://token-bar-9v8.pages.dev/release.json")!
    static let downloadPrefix = "https://github.com/rogu3bear/token-bar/releases/download/"
    static let key = "updateCheck.enabled.v1"
    static let bundleVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"

    var enabled: Bool { didSet { defaults.set(enabled, forKey: Self.key) } }
    private(set) var checking = false
    private(set) var outcome: Outcome?
    private(set) var checkedAt: Date?
    let currentVersion: String
    private let defaults: UserDefaults
    private let load: (URL) async throws -> Data

    init(defaults: UserDefaults = .standard, currentVersion: String = UpdateCheck.bundleVersion,
         load: @escaping (URL) async throws -> Data = UpdateCheck.fetch) {
        self.defaults = defaults
        self.currentVersion = currentVersion
        self.load = load
        enabled = defaults.object(forKey: Self.key) == nil ? true : defaults.bool(forKey: Self.key)
    }

    var availableRelease: ReleaseManifest? {
        if case .available(let manifest) = outcome { return manifest }
        return nil
    }

    /// Launch entry: nothing happens while the toggle is off.
    func checkAtLaunch() {
        guard enabled else { return }
        check()
    }

    func check() {
        guard !checking else { return }
        checking = true
        let load = self.load, current = currentVersion
        Task { @MainActor [weak self] in
            let outcome: Outcome
            do {
                let data = try await load(Self.manifestURL)
                let manifest = try JSONDecoder().decode(ReleaseManifest.self, from: data)
                outcome = Self.evaluate(manifest, current: current)
            } catch {
                outcome = .failed(Self.describe(error))
            }
            guard let self else { return }
            self.outcome = outcome
            self.checkedAt = Date()
            self.checking = false
        }
    }

    /// Preview and test seeding only; the launch path never calls this.
    func adopt(_ outcome: Outcome, at date: Date) {
        self.outcome = outcome
        checkedAt = date
        checking = false
    }

    static func evaluate(_ manifest: ReleaseManifest, current: String) -> Outcome {
        guard AppVersion.components(manifest.version) != nil else {
            return .failed("The release list names an unreadable version.")
        }
        guard manifest.available, manifest.notarized == true, AppVersion.isNewer(manifest.version, than: current) else {
            return .current(manifest.version)
        }
        guard downloadURL(for: manifest) != nil else {
            return .failed("Version \(manifest.version) is listed, but its download is not a GitHub release asset.")
        }
        return .available(manifest)
    }

    /// Only the notarized GitHub Release asset the manifest binds; anything else is not opened.
    static func downloadURL(for manifest: ReleaseManifest) -> URL? {
        guard let text = manifest.url, text.hasPrefix(downloadPrefix), let url = URL(string: text),
              url.scheme == "https", url.host == "github.com" else { return nil }
        return url
    }

    func openDownload() -> Bool {
        guard let manifest = availableRelease, let url = Self.downloadURL(for: manifest) else { return false }
        return NSWorkspace.shared.open(url)
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case UpdateCheckError.status(let code): return "The release list answered with status \(code)."
        case UpdateCheckError.notHTTP: return "The release list did not answer over HTTPS."
        case is DecodingError: return "The release list could not be read."
        case let urlError as URLError where urlError.code == .notConnectedToInternet || urlError.code == .networkConnectionLost:
            return "No network connection for the update check."
        default: return "The update check could not reach the Token Bar site."
        }
    }

    /// Ephemeral session: no cookies, no cache, no stored credentials, a fixed
    /// user agent without the app version, and a short timeout.
    static func fetch(_ url: URL) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpAdditionalHeaders = ["User-Agent": "TokenBar-update-check", "Accept": "application/json"]
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw UpdateCheckError.notHTTP }
        guard http.statusCode == 200 else { throw UpdateCheckError.status(http.statusCode) }
        return data
    }
}

/// Settings caption; the time is when this process last asked.
enum UpdateCheckStatus {
    static func text(_ check: UpdateCheck) -> String? {
        guard let outcome = check.outcome, let at = check.checkedAt else { return nil }
        let when = at.formatted(date: .omitted, time: .shortened)
        switch outcome {
        case .current(let version): return "Up to date. Latest release is \(version); checked at \(when)."
        case .available(let manifest): return "Token Bar \(manifest.version) is available; checked at \(when)."
        case .failed(let reason): return reason + " Checked at \(when)."
        }
    }
}
