import Foundation
let url = Feedback.url(version: "2.0.0 & injected=email@example.test")
let parsed = URLComponents(url: url, resolvingAgainstBaseURL: false)!
assert(parsed.scheme == "https" && parsed.host == "token-bar-9v8.pages.dev")
assert(parsed.path == "/feedback/" && parsed.queryItems?.count == 1)
assert(parsed.queryItems?.first?.name == "version")
assert(CodexInstallation.executable(environment: [:], isExecutable: { $0 == "/Applications/Codex.app/Contents/Resources/codex" }) == "/Applications/Codex.app/Contents/Resources/codex")
assert(CodexInstallation.executable(environment: ["CODEX_CLI_PATH": "/missing"], isExecutable: { $0 != "/missing" }) == nil)
print("PASS: feedback URL encoding/minimal metadata and explicit Codex executable discovery")
