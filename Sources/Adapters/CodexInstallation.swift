import Foundation

enum CodexInstallation {
    static func executable(environment: [String: String] = ProcessInfo.processInfo.environment,
                           userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
                           isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        if let override = environment["CODEX_CLI_PATH"] { return isExecutable(override) ? override : nil }
        let roots = ["/Applications", userHome.appendingPathComponent("Applications").path]
        let bundled = roots.flatMap { root in ["Codex.app", "ChatGPT.app"].map { root + "/" + $0 + "/Contents/Resources/codex" } }
        return (bundled + ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]).first(where: isExecutable)
    }
}
