import Foundation

/// Finds the tools that are actually installed.
///
/// A tool that is not installed returns nil, which switches its reader off.
/// Absence is never an error and never a zero: an uninstalled tool simply has
/// no usage to report.
enum HarnessDiscovery {
    private static func directory(_ path: String) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: path)
    }

    private static func override(_ variable: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard let value = environment[variable], !value.isEmpty else { return nil }
        return directory(value)
    }

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static func grok() -> URL? {
        override("GROK_HOME") ?? directory(home.appendingPathComponent(".grok").path)
    }

    /// Present when transcripts exist; the directory alone is not enough,
    /// because Claude Code creates its home before it records any usage.
    static func claudeCode(environment: [String: String] = ProcessInfo.processInfo.environment,
                           userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let root = ClaudeCodeUsage.home(environment: environment, userHome: userHome)
        return directory(root.appendingPathComponent("projects").path) == nil ? nil : root
    }

    /// Present when the database exists, not merely the directory.
    static func openCode(environment: [String: String] = ProcessInfo.processInfo.environment,
                         userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let candidates = [override("OPENCODE_HOME", environment: environment),
                          directory(userHome.appendingPathComponent(".local/share/opencode").path),
                          directory(userHome.appendingPathComponent(".opencode").path)]
        for case let root? in candidates
        where FileManager.default.fileExists(atPath: OpenCodeCatalog.database(in: root).path) {
            return root
        }
        return nil
    }
}

/// OpenCode's local usage catalog. Discovery, the file watcher, and the reader all use this file.
enum OpenCodeCatalog {
    static let fileName = "opencode.db"
    static var sidecarNames: [String] { [fileName, fileName + "-wal", fileName + "-shm"] }
    static func database(in home: URL) -> URL { home.appendingPathComponent(fileName) }
}
