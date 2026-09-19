import AppKit

/// Feedback starts in a browser. No local account, log, task, or email data is attached.
enum Feedback {
    static let versionLimit = 40
    static func url(version: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development") -> URL {
        var components = URLComponents(string: "https://token-bar-9v8.pages.dev/feedback/")!
        components.queryItems = [URLQueryItem(name: "version", value: String(version.prefix(versionLimit)))]
        return components.url!
    }
    static func open() -> Bool { NSWorkspace.shared.open(url()) }
}
