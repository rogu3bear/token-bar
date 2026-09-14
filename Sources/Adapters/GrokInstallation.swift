import Foundation

enum GrokInstallation {
    static func executable(environment: [String: String] = ProcessInfo.processInfo.environment,
                           userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
                           isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        if let override = environment["GROK_CLI_PATH"] { return isExecutable(override) ? override : nil }
        let path = (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/grok" }
        let extras = [userHome.appendingPathComponent(".local/bin/grok").path, "/opt/homebrew/bin/grok", "/usr/local/bin/grok"]
        return (path + extras).first(where: isExecutable)
    }
}
