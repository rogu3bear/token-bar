import Foundation

enum GrokInstallation {
    static func executable(environment: [String: String] = ProcessInfo.processInfo.environment,
                           userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
                           isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        CLIExecutable.path(name: "grok", overrideVariable: "GROK_CLI_PATH",
                           extras: [userHome.appendingPathComponent(".local/bin/grok").path, "/opt/homebrew/bin/grok", "/usr/local/bin/grok"],
                           environment: environment, isExecutable: isExecutable)
    }
}
