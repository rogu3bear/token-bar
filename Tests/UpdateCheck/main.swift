import Foundation
extension ReleaseManifest {
    func withSHA(_ sha: String) -> ReleaseManifest { var copy = self; copy.sha256 = sha; return copy }
}
let suite = "local.codex-token-bar.tests." + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }

assert(AppVersion.isNewer("0.1.10", than: "0.1.9"), "numeric, not lexical")
assert(!AppVersion.isNewer("0.1.9", than: "0.1.10"))
assert(!AppVersion.isNewer("0.1.9", than: "0.1.9"))
assert(AppVersion.isNewer("0.2.0", than: "0.1.99"))
assert(AppVersion.isNewer("1.0.0", than: "0.9.9"))
assert(!AppVersion.isNewer("0.1.10", than: "development"), "a development build is never behind")
assert(!AppVersion.isNewer("1.0", than: "0.1.9"), "malformed manifest versions are not newer")
assert(!AppVersion.isNewer("0.1.10-rc1", than: "0.1.9"))
assert(!AppVersion.isNewer("", than: "0.1.9"))
assert(AppVersion.components(" 0.1.10\n") == [0, 1, 10])
print("PASS: version ordering is numeric and refuses non-release strings")

let asset = UpdateCheck.downloadPrefix + "v0.1.10/TokenBar-0.1.10-arm64.pkg"
let newer = ReleaseManifest(version: "0.1.10", available: true, url: asset, sha256: String(repeating: "a", count: 64), notarized: true)
assert(UpdateCheck.evaluate(newer, current: "0.1.9") == .available(newer))
assert(UpdateCheck.evaluate(newer, current: "0.1.10") == .current("0.1.10"))
assert(UpdateCheck.evaluate(newer, current: "0.2.0") == .current("0.1.10"))
assert(UpdateCheck.evaluate(newer, current: "development") == .current("0.1.10"))
var unavailable = newer; unavailable.available = false
assert(UpdateCheck.evaluate(unavailable, current: "0.1.9") == .current("0.1.10"), "an unpublished successor is not offered")
var unnotarized = newer; unnotarized.notarized = false
assert(UpdateCheck.evaluate(unnotarized, current: "0.1.9") == .current("0.1.10"))
var missingNotarized = newer; missingNotarized.notarized = nil
assert(UpdateCheck.evaluate(missingNotarized, current: "0.1.9") == .current("0.1.10"))
var elsewhere = newer; elsewhere.url = "https://example.com/TokenBar.pkg"
if case .failed = UpdateCheck.evaluate(elsewhere, current: "0.1.9") {} else { preconditionFailure("non-GitHub asset must not be offered") }
var insecure = newer; insecure.url = "http://github.com/rogu3bear/token-bar/releases/download/x.pkg"
assert(UpdateCheck.downloadURL(for: insecure) == nil)
assert(UpdateCheck.downloadURL(for: newer)?.host == "github.com")
var unreadable = newer; unreadable.version = "latest"
if case .failed = UpdateCheck.evaluate(unreadable, current: "0.1.9") {} else { preconditionFailure("unreadable version is not current") }
print("PASS: only a newer, available, notarized GitHub release asset is offered")

let decoded = try JSONDecoder().decode(ReleaseManifest.self, from: Data("""
{"version":"0.1.9","available":true,"platform":"Apple silicon","url":"\(UpdateCheck.downloadPrefix)v0.1.9/TokenBar-0.1.9-arm64.pkg","sha256":"f3","notarized":true,"status":"Signed"}
""".utf8))
assert(decoded.version == "0.1.9" && decoded.notarized == true, "extra manifest keys are ignored")
let sparse = try JSONDecoder().decode(ReleaseManifest.self, from: Data(#"{"version":"0.2.0","available":false}"#.utf8))
assert(sparse.url == nil && sparse.notarized == nil)
print("PASS: manifest decoding tolerates optional and extra fields")

func settle(_ check: UpdateCheck, file: StaticString = #file, line: UInt = #line) {
    let deadline = Date().addingTimeInterval(5)
    while check.checking && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    precondition(!check.checking, "check did not settle", file: file, line: line)
}

var loads = 0
let manifestJSON = Data("""
{"version":"0.1.10","available":true,"url":"\(asset)","sha256":"ab","notarized":true}
""".utf8)
let fresh = UpdateCheck(defaults: defaults, currentVersion: "0.1.9") { _ in loads += 1; return manifestJSON }
assert(fresh.enabled, "the check is on until turned off")
assert(fresh.outcome == nil && fresh.checkedAt == nil)
fresh.enabled = false
assert(UpdateCheck(defaults: defaults, currentVersion: "0.1.9") { _ in preconditionFailure("must not load") }.enabled == false, "the toggle persists")
fresh.checkAtLaunch()
settle(fresh)
assert(loads == 0 && fresh.outcome == nil, "a disabled check never touches the network")
fresh.enabled = true
fresh.checkAtLaunch()
fresh.check()
settle(fresh)
assert(loads == 1, "one request per launch; a second call while checking is ignored")
assert(fresh.outcome == .available(newer.withSHA("ab")) && fresh.checkedAt != nil, "\(String(describing: fresh.outcome))")
assert(fresh.availableRelease?.version == "0.1.10")
assert(UpdateCheckStatus.text(fresh)?.contains("0.1.10 is available") == true)
print("PASS: launch check honors the toggle, runs once, and reports the newer release")

let current = UpdateCheck(defaults: defaults, currentVersion: "0.1.10") { _ in manifestJSON }
current.check(); settle(current)
assert(current.outcome == .current("0.1.10") && current.availableRelease == nil)
assert(UpdateCheckStatus.text(current)?.hasPrefix("Up to date.") == true)

struct Offline: Error {}
let offline = UpdateCheck(defaults: defaults, currentVersion: "0.1.9") { _ in throw URLError(.notConnectedToInternet) }
offline.check(); settle(offline)
assert(offline.outcome == .failed("No network connection for the update check."), "\(String(describing: offline.outcome))")
assert(offline.availableRelease == nil && offline.checkedAt != nil)
let garbled = UpdateCheck(defaults: defaults, currentVersion: "0.1.9") { _ in Data("<html>".utf8) }
garbled.check(); settle(garbled)
assert(garbled.outcome == .failed("The release list could not be read."))
let denied = UpdateCheck(defaults: defaults, currentVersion: "0.1.9") { _ in throw UpdateCheckError.status(503) }
denied.check(); settle(denied)
assert(denied.outcome == .failed("The release list answered with status 503."))
assert(UpdateCheck.describe(Offline()) == "The update check could not reach the Token Bar site.")
assert(UpdateCheck.manifestURL.host == "token-bar-9v8.pages.dev" && UpdateCheck.manifestURL.path == "/release.json")
let seeded = UpdateCheck(defaults: defaults, currentVersion: "0.1.9") { _ in preconditionFailure("seeding never loads") }
seeded.adopt(.available(newer), at: Date(timeIntervalSince1970: 0))
assert(seeded.availableRelease == newer && seeded.checkedAt == Date(timeIntervalSince1970: 0) && !seeded.checking)
print("PASS: failures stay labeled and never become an available release; previews seed without loading")
