import Foundation
let url = Feedback.url(version: "2.0.0 & injected=email@example.test")
let parsed = URLComponents(url: url, resolvingAgainstBaseURL: false)!
assert(parsed.scheme == "https" && parsed.host == "token-bar-9v8.pages.dev")
assert(parsed.path == "/feedback/" && parsed.queryItems?.count == 1)
assert(parsed.queryItems?.first?.name == "version")
assert(CodexInstallation.executable(environment: [:], isExecutable: { $0 == "/Applications/Codex.app/Contents/Resources/codex" }) == "/Applications/Codex.app/Contents/Resources/codex")
assert(CodexInstallation.executable(environment: ["CODEX_CLI_PATH": "/missing"], isExecutable: { $0 != "/missing" }) == nil)
assert(CodexInstallation.executable(environment: ["CODEX_CLI_PATH": ""], isExecutable: { $0 == "/Applications/Codex.app/Contents/Resources/codex" }) == "/Applications/Codex.app/Contents/Resources/codex",
       "Empty CODEX_CLI_PATH is absence, not a path")
let home = URL(fileURLWithPath: "/home")
assert(CLIExecutable.path(name: "grok", overrideVariable: "GROK_CLI_PATH", extras: [home.appendingPathComponent(".local/bin/grok").path],
                          environment: ["PATH": "/one:/two"], isExecutable: { $0 == "/two/grok" }) == "/two/grok")
assert(CLIExecutable.path(name: "grok", overrideVariable: "GROK_CLI_PATH", extras: [home.appendingPathComponent(".local/bin/grok").path],
                          environment: ["PATH": "/usr/bin", "GROK_CLI_PATH": ""], isExecutable: { $0 == home.appendingPathComponent(".local/bin/grok").path })
       == home.appendingPathComponent(".local/bin/grok").path)
assert(CLIExecutable.path(name: "claude", overrideVariable: "CLAUDE_CLI_PATH", extras: [],
                          environment: ["CLAUDE_CLI_PATH": "/missing/claude", "PATH": "/bin"], isExecutable: { _ in false }) == nil)
assert(CLIExecutable.resolved(override: "/explicit", candidates: ["/guess"], isExecutable: { $0 == "/explicit" }) == "/explicit")
assert(CLIExecutable.resolved(override: "/explicit", candidates: ["/guess"], isExecutable: { $0 == "/guess" }) == nil)
print("PASS: feedback URL encoding/minimal metadata and shared CLI executable discovery")
