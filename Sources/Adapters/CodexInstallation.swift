import Foundation

/// First executable wins: a non-empty override, then the caller’s candidate list.
/// Empty override is absence, not a path. A missing override binary is not guessed.
enum CLIExecutable {
    static func resolved(override: String?, candidates: [String], isExecutable: (String) -> Bool) -> String? {
        if let override, !override.isEmpty { return isExecutable(override) ? override : nil }
        return candidates.first(where: isExecutable)
    }

    static func path(name: String, overrideVariable: String, extras: [String],
                     environment: [String: String], isExecutable: (String) -> Bool) -> String? {
        let path = (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/" + name }
        return resolved(override: environment[overrideVariable], candidates: path + extras, isExecutable: isExecutable)
    }
}

enum CodexInstallation {
    static func executable(environment: [String: String] = ProcessInfo.processInfo.environment,
                           userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
                           isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        let roots = ["/Applications", userHome.appendingPathComponent("Applications").path]
        let bundled = roots.flatMap { root in ["Codex.app", "ChatGPT.app"].map { root + "/" + $0 + "/Contents/Resources/codex" } }
        return CLIExecutable.resolved(override: environment["CODEX_CLI_PATH"],
                                      candidates: bundled + ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"],
                                      isExecutable: isExecutable)
    }
}
