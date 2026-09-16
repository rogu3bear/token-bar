import Foundation
import AppKit
let suite = "local.codex-token-bar.tests." + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let settings = MenuBarPreferences(defaults: defaults)
assert(settings.configuration.enabled == [.quota, .rate, .dial])
settings.configuration.enabled = [.quota, .rate]
settings.configuration.compact = true
settings.configuration.unit = "h"
settings.configuration.separator = " | "
settings.move(.quota, by: -1)
let restored = MenuBarPreferences(defaults: defaults)
assert(restored.configuration == settings.configuration, "Every option and order must survive reload")
assert(restored.configuration.title(values: [.quota: "43% left", .rate: "~3600 t/h"]) == "43% left | ~3600 t/h")
restored.configuration.enabled = []
assert(restored.configuration.title(values: [:]) == "◈", "All fields off must leave an accessible item")
restored.configuration.order = [.rate, .rate]
restored.configuration.unit = "invalid"
restored.configuration.normalize()
assert(Set(restored.configuration.order) == Set(MenuBarPart.allCases))
assert(restored.configuration.order.count == MenuBarPart.allCases.count)
assert(restored.configuration.unit == "dashboard")
restored.reset()
assert(MenuBarPreferences(defaults: defaults).configuration == MenuBarConfiguration())
print("PASS: defaults, persisted visibility/order/format/units, rendering order, icon fallback, normalization and reset")
var older = MenuBarConfiguration()
older.enabled = [.activity, .rate]
older.order = [.icon, .activity, .rate, .quota, .zero]
older.normalize()
assert(older.order.suffix(4) == [.dial, .risk, .fable, .fablePace] && older.enabled == [.activity, .rate], "Add new option without changing saved selections")
restored.configuration.enabled = [.dial, .quota]
assert(MenuBarPreferences(defaults: defaults).configuration.enabled == [.dial, .quota])
assert(MenuBarDial.fraction(value: 150, minimum: 100, maximum: 200) == 0.5)
assert(MenuBarDial.fraction(value: 5, minimum: 100, maximum: 200) == 0)
assert(MenuBarDial.fraction(value: 500, minimum: 100, maximum: 200) == 1)
assert(MenuBarDial.fraction(value: 10, minimum: 10, maximum: 10) == 0)
print("PASS: dial preference migration, dial/quota persistence, dynamic range and clamping")
let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
let monitor = LiveMonitor(home: fixture, stateURL: fixture.appendingPathComponent("absent.json"))
let meter = Tachometer()
meter.rawRate = 2; meter.rate = 2; meter.hasRate = true; meter.unit = .minute
var config = MenuBarConfiguration()
let now = Date()
assert(MenuBarPresentation.values(config, meter: meter, monitor: monitor, now: now)[.rate] == "~120 tok/m")
config.unit = "h"
assert(MenuBarPresentation.values(config, meter: meter, monitor: monitor, now: now)[.rate] == "~7.2k tok/h")
assert(meter.unit == .minute, "Independent menu units must not alter dashboard units")
meter.hasRate = false
assert(MenuBarPresentation.values(config, meter: meter, monitor: monitor, now: now)[.rate] == "— tok/h")
let quota = QuotaReading(accountID: "a", bucket: "codex", name: "Codex", window: "primary", minutes: 10080, used: 60, reset: now.addingTimeInterval(86400), date: now)
monitor.currentID = "a"
monitor.state.accounts["a"] = LiveAccount(id: "a", email: "fixture", plan: "pro", observed: now, quotas: [quota])
assert(MenuBarPresentation.values(config, meter: meter, monitor: monitor, now: now)[.quota] == "40% remaining")
assert(MenuBarPresentation.values(config, meter: meter, monitor: monitor, now: now.addingTimeInterval(121))[.quota] == "Quota unavailable")
monitor.currentID = "b"
assert(MenuBarPresentation.values(config, meter: meter, monitor: monitor, now: now)[.quota] == "Quota unavailable", "Never show previous account quota")
config.enabled = [.dial, .quota]; config.order = [.dial, .quota]
let visual = MenuBarPresentation.attributed(config, meter: meter, monitor: monitor, now: now)
assert(visual.attribute(.attachment, at: 0, effectiveRange: nil) != nil)
assert(visual.string == "\u{fffc}  Quota unavailable", "Attachment and quota must follow selected order")
config.enabled = []
assert(MenuBarPresentation.attributed(config, meter: meter, monitor: monitor, now: now).string == "◈")
let fallbackIcon = MenuBarPresentation.attributed(config, meter: meter, monitor: monitor, now: now, accent: .systemPink)
assert((fallbackIcon.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor) == .systemPink)
config.enabled = [.icon]; config.order = [.icon]
let selectedIcon = MenuBarPresentation.attributed(config, meter: meter, monitor: monitor, now: now, accent: .systemPink)
assert((selectedIcon.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor) == .systemPink)
print("PASS: cross-surface units, independent override, missing rate, current/stale/switched-account quota, native attachment order and fallback")

// Existing v1 preferences have no tool field; every other choice must survive.
var legacyObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(restored.configuration)) as! [String: Any]
legacyObject.removeValue(forKey: "tool")
legacyObject["compact"] = true
legacyObject["unit"] = "h"
defaults.set(try JSONSerialization.data(withJSONObject: legacyObject), forKey: "menuBarConfiguration.v1")
let migratedTools = MenuBarPreferences(defaults: defaults)
assert(migratedTools.configuration.tool == .auto && migratedTools.configuration.compact && migratedTools.configuration.unit == "h")
migratedTools.configuration.tool = .claude
assert(MenuBarPreferences(defaults: defaults).configuration.tool == .claude)
assert(MenuBarPresentation.values(config, meter: meter, monitor: monitor, now: now, tool: .claude)[.quota] == "Claude quota unavailable")
assert(MenuBarPresentation.title(config, meter: meter, monitor: monitor, now: now, tool: .claude).hasPrefix("Claude · "))
let named = MenuBarPresentation.attributed(config, meter: meter, monitor: monitor, now: now, accent: NSColor(LiveTool.claude.color), tool: .claude)
assert(named.string.hasPrefix("Claude"), "Menu selection always identifies its tool")
let independentCodex = Tachometer(), independentClaude = Tachometer()
independentClaude.hasRate = true; independentClaude.lastReport = now
assert(MenuBarTool.auto.resolve(codex: independentCodex, claude: independentClaude) == .claude)
assert(MenuBarTool.codex.resolve(codex: independentCodex, claude: independentClaude) == .codex)
independentClaude.hasRate = false
assert(MenuBarTool.auto.resolve(codex: independentCodex, claude: independentClaude) == .codex)
print("PASS: legacy menu choices survive tool migration; selection, Auto fallback and Claude quota boundaries")

let cacheNow = Date(timeIntervalSince1970: 2_000_000_000)
func cacheData(account: String = "a", signedIn: String = "a", used: Double = 58, age: Double = 0) throws -> Data {
    let reset = ISO8601DateFormatter().string(from: cacheNow.addingTimeInterval(14400))
    return try JSONSerialization.data(withJSONObject: ["oauthAccount": ["accountUuid": signedIn], "cachedUsageUtilization": ["accountUuid": account, "fetchedAtMs": cacheNow.addingTimeInterval(-age).timeIntervalSince1970 * 1000, "utilization": ["five_hour": ["utilization": used, "resets_at": reset]]]])
}
let freshClaude = try JSONDecoder().decode(ClaudeQuotaCache.self, from: cacheData()).readings(now: cacheNow)
assert(freshClaude.count == 1 && freshClaude[0].used == 58 && freshClaude[0].accountID.hasPrefix("claude:"))
for data in [try cacheData(account: "other"), try cacheData(age: 1800), try cacheData(age: -1), try cacheData(used: -1), try cacheData(used: 101)] {
    let decoded = try JSONDecoder().decode(ClaudeQuotaCache.self, from: data)
    assert(decoded.readings(now: cacheNow).isEmpty)
}
let zeroCache = try JSONDecoder().decode(ClaudeQuotaCache.self, from: cacheData(used: 0))
assert(zeroCache.readings(now: cacheNow).first?.used == 0)
var firstClaude = freshClaude[0]
firstClaude.used = 53; firstClaude.date = cacheNow.addingTimeInterval(-300)
let ownQuota = ToolQuotaState(readings: freshClaude, samples: [firstClaude] + freshClaude, horizon: ClaudeQuotaSource.horizon)
let claudeValues = MenuBarPresentation.values(config, meter: meter, monitor: monitor, now: cacheNow, tool: .claude, claudeQuota: ownQuota)
assert(claudeValues[.quota] == "Claude 42% remaining")
assert(claudeValues[.zero] != "Zero —")
let laterClaude = MenuBarPresentation.values(config, meter: meter, monitor: monitor, now: cacheNow.addingTimeInterval(120), tool: .claude, claudeQuota: ownQuota)
assert(laterClaude[.quota] == "Claude 42% remaining", "Claude Code refreshes on demand; two minutes is Codex's horizon, not Claude's")
let staleClaude = MenuBarPresentation.values(config, meter: meter, monitor: monitor, now: cacheNow.addingTimeInterval(1800), tool: .claude, claudeQuota: ownQuota)
assert(staleClaude[.quota] == "Claude quota unavailable" && staleClaude[.zero] == "Zero —")
let codexHorizon = ToolQuotaState(readings: freshClaude, samples: [firstClaude] + freshClaude, horizon: Runway.defaultHorizon)
assert(MenuBarPresentation.values(config, meter: meter, monitor: monitor, now: cacheNow.addingTimeInterval(120), tool: .claude, claudeQuota: codexHorizon)[.quota] == "Claude quota unavailable")
assert(Runway.ageLabel(freshClaude[0], now: cacheNow.addingTimeInterval(90)) == "")
assert(Runway.ageLabel(freshClaude[0], now: cacheNow.addingTimeInterval(660)) == " · 11 min ago")
assert(ClaudeQuotaSource.relayHelp.contains("claude-statusline-relay.sh") && ClaudeQuotaSource.relayHelp.contains("statusLine"))
let mixed = Runway.estimate(freshClaude[0], samples: monitor.state.samples + [freshClaude[0]], now: cacheNow)
assert(mixed.exhaustion == nil, "Codex observations cannot supply Claude's burn slope")
print("PASS: Claude cache account binding, timestamp freshness, bounds, real zero, independent runway and selected-tool quota")

// Status-line relay has no originating account identity and is never quota evidence.
func relayData(used: Double = 41, week: Double? = 12, age: Double = 0, resetIn: Double = 14400, limits: Bool = true) throws -> Data {
    var rate: [String: Any] = ["five_hour": ["used_percentage": used, "resets_at": cacheNow.addingTimeInterval(resetIn).timeIntervalSince1970]]
    if let week { rate["seven_day"] = ["used_percentage": week, "resets_at": cacheNow.addingTimeInterval(6 * 86400).timeIntervalSince1970] }
    var line: [String: Any] = ["model": ["display_name": "Opus"], "session_id": "s"]
    if limits { line["rate_limits"] = rate }
    return try JSONSerialization.data(withJSONObject: ["received_at_ms": cacheNow.addingTimeInterval(-age).timeIntervalSince1970 * 1000, "statusline": line])
}
let relayRoot = FileManager.default.temporaryDirectory.appendingPathComponent("tokenbar-relay-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: relayRoot, withIntermediateDirectories: true)
let cacheFile = relayRoot.appendingPathComponent("claude.json"), relayFile = relayRoot.appendingPathComponent("claude-statusline.json")
try cacheData(age: 3600).write(to: cacheFile)
assert(ClaudeQuotaMonitor.readings(cacheURL: cacheFile, relayURL: relayFile, now: cacheNow).isEmpty, "stale cache and no relay file")
try relayData().write(to: relayFile)
let fromFiles = ClaudeQuotaMonitor.readings(cacheURL: cacheFile, relayURL: relayFile, now: cacheNow)
assert(fromFiles.isEmpty, "an identity-free relay cannot replace a stale account-bound cache")
try cacheData(account: "a", signedIn: "b", age: 3600).write(to: cacheFile)
assert(ClaudeQuotaMonitor.readings(cacheURL: cacheFile, relayURL: relayFile, now: cacheNow).isEmpty, "account A relay cannot become account B quota")
// A new monitor/read after a restart has the same files and must also reject it.
let restarted = ClaudeQuotaMonitor(cacheURL: cacheFile, relayURL: relayFile)
assert(ClaudeQuotaMonitor.readings(cacheURL: restarted.cacheURL, relayURL: restarted.relayURL, now: cacheNow).isEmpty)
try cacheData().write(to: cacheFile)
let cacheBound = ClaudeQuotaMonitor.readings(cacheURL: cacheFile, relayURL: relayFile, now: cacheNow)
assert(cacheBound.count == 1 && cacheBound[0].used == 58, "fresh account-matched cache wins over newer identity-free relay")
try cacheData(account: "b", signedIn: "b", used: 22).write(to: cacheFile)
let accountB = ClaudeQuotaMonitor.readings(cacheURL: cacheFile, relayURL: relayFile, now: cacheNow)
assert(accountB.count == 1 && accountB[0].used == 22 && accountB[0].accountID == ClaudeQuotaSource.accountID("b"))
try Data("{}".utf8).write(to: cacheFile)
assert(ClaudeQuotaMonitor.readings(cacheURL: cacheFile, relayURL: relayFile, now: cacheNow).isEmpty, "no signed-in account, no relay reading")
try? FileManager.default.removeItem(at: relayRoot)
print("PASS: identity-free relay rejected across stale cache, account switch, sign-out and restart; account-bound cache retained")

// Connect Claude Code: settings edits touch only statusLine, keep a capped backup, and undo exactly.
let connectRoot = FileManager.default.temporaryDirectory.appendingPathComponent("tokenbar-connect-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: connectRoot, withIntermediateDirectories: true)
let configDir = connectRoot.appendingPathComponent("claude-config"), supportDir = connectRoot.appendingPathComponent("support")
assert(ClaudeStatuslineConnection.settingsURL(environment: ["CLAUDE_CONFIG_DIR": configDir.path], home: connectRoot).path == configDir.appendingPathComponent("settings.json").path)
assert(ClaudeStatuslineConnection.settingsURL(environment: [:], home: connectRoot).path == connectRoot.appendingPathComponent(".claude/settings.json").path)
let relayTarget = ClaudeStatuslineConnection.stableRelayURL(support: supportDir)
assert(relayTarget.path.hasSuffix("CodexTokenBar/claude-statusline-relay.sh"))
let quotedRelay = ClaudeStatuslineConnection.quoted("/Users/x/Library/Application Support/it's/relay.sh")
assert(quotedRelay == "'/Users/x/Library/Application Support/it'\\''s/relay.sh'", quotedRelay)
let relayPath = relayTarget.path
let noStatusLine: [String: Any] = ["model": "opus", "permissions": ["allow": ["Bash"]]]
let connectedAbsent = try ClaudeStatuslineConnection.connect(noStatusLine, relay: relayPath)!
assert((connectedAbsent.settings["statusLine"] as? [String: String]) == ["type": "command", "command": ClaudeStatuslineConnection.quoted(relayPath)])
assert(connectedAbsent.settings["model"] as? String == "opus" && (connectedAbsent.settings["permissions"] as? [String: [String]]) == ["allow": ["Bash"]])
assert(connectedAbsent.previous == ClaudeStatuslineConnection.Previous(present: false, raw: nil))
assert(ClaudeStatuslineConnection.isConnected(connectedAbsent.settings, relay: relayPath))
let twice = try ClaudeStatuslineConnection.connect(connectedAbsent.settings, relay: relayPath)
assert(twice == nil, "connecting twice changes nothing")
let existing: [String: Any] = ["statusLine": ["type": "command", "command": "~/.claude/scripts/statusline.sh", "padding": 1]]
let connectedExisting = try ClaudeStatuslineConnection.connect(existing, relay: relayPath)!
let chained = connectedExisting.settings["statusLine"] as! [String: Any]
assert(chained["command"] as? String == ClaudeStatuslineConnection.command(relay: relayPath, existing: "~/.claude/scripts/statusline.sh") && chained["padding"] as? Int == 1)
assert(connectedExisting.previous.present && connectedExisting.previous.raw != nil)
let restoredChain = ClaudeStatuslineConnection.disconnect(connectedExisting.settings, relay: relayPath, previous: connectedExisting.previous)!
assert((restoredChain["statusLine"] as! [String: Any])["command"] as? String == "~/.claude/scripts/statusline.sh", "relay prefix stripped keeps the chained command")
func statusOutput(_ command: String) throws -> String {
    let process = Process(), input = Pipe(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    var environment = ProcessInfo.processInfo.environment
    environment["TOKEN_BAR_CLAUDE_STATUSLINE"] = connectRoot.appendingPathComponent("shell-relay.json").path
    process.environment = environment
    process.standardInput = input; process.standardOutput = output
    try process.run()
    input.fileHandleForWriting.write(Data("{\"sample\":\"value\"}\n".utf8))
    try input.fileHandleForWriting.close()
    let result = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: result, as: UTF8.self)
}
let shippingRelay = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Assets/claude-statusline-relay.sh").path
for original in [
    "FOO=bar /bin/sh -c 'printf %s \"$FOO\"'",
    "read line; printf '%s' \"$line\" | tr a-z A-Z; printf ':done'",
    "printf '%s' \"quoted ' value\" && printf ':ok'"
] {
    let expected = try statusOutput(original)
    let wrapped = ClaudeStatuslineConnection.command(relay: shippingRelay, existing: original)
    let actual = try statusOutput(wrapped)
    assert(actual == expected && !actual.isEmpty, "existing shell syntax and stdin must survive Connect")
    let settings: [String: Any] = ["statusLine": ["type": "command", "command": original, "padding": 2]]
    let connected = try ClaudeStatuslineConnection.connect(settings, relay: shippingRelay)!
    let restored = ClaudeStatuslineConnection.disconnect(connected.settings, relay: shippingRelay, previous: connected.previous)!
    let originalData = try ClaudeStatuslineConnection.serialize(settings)
    let restoredData = try ClaudeStatuslineConnection.serialize(restored)
    assert(originalData == restoredData, "Disconnect restores the original shell command and metadata exactly")
}
let removed = ClaudeStatuslineConnection.disconnect(connectedAbsent.settings, relay: relayPath, previous: connectedAbsent.previous)!
assert(removed["statusLine"] == nil && removed["model"] as? String == "opus", "relay alone with no previous status line is removed")
var edited = connectedAbsent.settings
edited["statusLine"] = ["type": "command", "command": ClaudeStatuslineConnection.quoted(relayPath) + " ./mine.sh"]
let stripped = ClaudeStatuslineConnection.disconnect(edited, relay: relayPath, previous: connectedAbsent.previous)!
assert((stripped["statusLine"] as! [String: Any])["command"] as? String == "./mine.sh", "a later user edit survives disconnect")
assert(ClaudeStatuslineConnection.disconnect(noStatusLine, relay: relayPath, previous: nil) == nil, "disconnect without the relay changes nothing")
let previousFull = ClaudeStatuslineConnection.Previous(present: true, raw: try JSONSerialization.data(withJSONObject: ["type": "command", "command": "old.sh"]))
let soloThenRestore = ClaudeStatuslineConnection.disconnect(["statusLine": ["type": "command", "command": ClaudeStatuslineConnection.quoted(relayPath)]], relay: relayPath, previous: previousFull)!
assert((soloThenRestore["statusLine"] as! [String: Any])["command"] as? String == "old.sh", "the remembered status line is restored verbatim")
do { _ = try ClaudeStatuslineConnection.parse(Data("[1,2]".utf8)); assert(false, "a non-object settings file must not be rewritten") } catch {}
let parsedNil = try ClaudeStatuslineConnection.parse(nil), parsedBlank = try ClaudeStatuslineConnection.parse(Data(" \n".utf8))
assert(parsedNil.isEmpty && parsedBlank.isEmpty)
// File behavior: backups capped at three, atomic replace, permissions kept, relay installed once.
let settingsFile = configDir.appendingPathComponent("settings.json")
try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
try Data("{\"model\":\"opus\"}".utf8).write(to: settingsFile)
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsFile.path)
for step in 0..<5 {
    try ClaudeStatuslineConnection.write(Data("{\"step\":\(step)}".utf8), to: settingsFile, now: Date(timeIntervalSince1970: 1_800_000_000 + Double(step)))
}
let backups = ClaudeStatuslineConnection.backups(in: configDir)
assert(backups.count == 3 && backups.allSatisfy { $0.lastPathComponent.hasPrefix(ClaudeStatuslineConnection.backupPrefix) }, "\(backups)")
let lastBackup = try String(contentsOf: backups.last!), currentSettings = try String(contentsOf: settingsFile)
assert(lastBackup.contains("\"step\":3") && currentSettings.contains("\"step\":4"))
let keptPermissions = try FileManager.default.attributesOfItem(atPath: settingsFile.path)
assert((keptPermissions[.posixPermissions] as? Int) == 0o600)
let configEntries = try FileManager.default.contentsOfDirectory(atPath: configDir.path)
assert(configEntries.allSatisfy { !$0.contains(".tmp") }, "no temporary file left behind")
let bundleRelay = connectRoot.appendingPathComponent("bundled-relay.sh")
try Data("#!/bin/sh\nexit 0\n".utf8).write(to: bundleRelay)
try ClaudeStatuslineConnection.installRelay(from: bundleRelay, to: relayTarget)
let firstInstall = try FileManager.default.attributesOfItem(atPath: relayTarget.path)
let relayDirAttributes = try FileManager.default.attributesOfItem(atPath: relayTarget.deletingLastPathComponent().path)
assert((firstInstall[.posixPermissions] as? Int) == 0o755 && (relayDirAttributes[.posixPermissions] as? Int) == 0o700)
try ClaudeStatuslineConnection.installRelay(from: bundleRelay, to: relayTarget)
let secondInstall = try FileManager.default.attributesOfItem(atPath: relayTarget.path)
assert((firstInstall[.modificationDate] as? Date) == (secondInstall[.modificationDate] as? Date), "identical bytes are not rewritten")
try Data("#!/bin/sh\nexit 1\n".utf8).write(to: bundleRelay)
try ClaudeStatuslineConnection.installRelay(from: bundleRelay, to: relayTarget)
let replacedRelay = try String(contentsOf: relayTarget)
assert(replacedRelay.contains("exit 1"), "changed bytes replace the stable copy")
// Model round trip through real files with an isolated defaults suite.
let connectDefaults = UserDefaults(suiteName: "tokenbar-connect-\(UUID().uuidString)")!
try Data("{\"statusLine\":{\"type\":\"command\",\"command\":\"mine.sh\"}}".utf8).write(to: settingsFile)
let connection = ClaudeConnectionModel(settingsURL: settingsFile, relayURL: relayTarget, bundleRelayURL: bundleRelay, defaults: connectDefaults)
connection.refresh(relayObserved: false)
assert(connection.status == .notConnected && connection.caveat == nil)
assert(connection.connect() && connection.status == .configured && connection.error == nil)
let connectedText = try String(contentsOf: settingsFile)
assert(connectedText.contains(ClaudeStatuslineConnection.command(relay: relayPath, existing: "mine.sh")))
connection.refresh(relayObserved: true); assert(connection.status == .connected)
try Data("{\"statusLine\":{\"type\":\"command\",\"command\":\"local.sh\"}}".utf8).write(to: configDir.appendingPathComponent("settings.local.json"))
connection.refresh(relayObserved: true); assert(connection.caveat?.contains("settings.local.json") == true, "a local override is reported, not fixed")
assert(connection.disconnect() && connection.status == .notConnected)
let disconnectedText = try String(contentsOf: settingsFile)
assert(disconnectedText.contains("\"command\" : \"mine.sh\"") && !disconnectedText.contains("relay"), disconnectedText)
assert(connectDefaults.data(forKey: ClaudeStatuslineConnection.previousKey) == nil)
let previewConnection = ClaudeConnectionModel(fixture: .connected)
assert(!previewConnection.connect() && !previewConnection.disconnect() && previewConnection.status == .connected, "preview fixtures never touch files")
let beforeFailedConnect = try Data(contentsOf: settingsFile)
for source in [nil, connectRoot.appendingPathComponent("missing-relay.sh")] as [URL?] {
    let failedConnection = ClaudeConnectionModel(settingsURL: settingsFile, relayURL: relayTarget,
        bundleRelayURL: source, defaults: connectDefaults)
    assert(!failedConnection.connect() && failedConnection.error?.contains("Relay install failed") == true)
    let afterFailedConnect = try Data(contentsOf: settingsFile)
    assert(afterFailedConnect == beforeFailedConnect, "failed relay installation must preserve settings")
    assert(connectDefaults.data(forKey: ClaudeStatuslineConnection.previousKey) == nil)
    assert(failedConnection.status == .notConnected)
}
try? FileManager.default.removeItem(at: connectRoot)
print("PASS: Connect Claude Code edits only statusLine, chains or restores commands, caps backups, installs the relay once and reports local overrides")

let soloCodex = Tachometer(), joiningClaude = Tachometer()
assert(LiveTool.visible(codex: soloCodex, claude: joiningClaude).isEmpty)
assert(LiveTool.compact(codex: soloCodex, claude: joiningClaude, remaining: { _ in nil }).isEmpty)
assert(LiveTool.compact(codex: soloCodex, claude: joiningClaude, remaining: { $0 == .claude ? 0 : 40 }) == [.claude])
assert(LiveTool.compact(codex: soloCodex, claude: joiningClaude, remaining: { _ in 0 }) == [.claude],
       "Unused Codex remaining 0 does not earn a popover row")
soloCodex.hasRate = true
assert(LiveTool.visible(codex: soloCodex, claude: joiningClaude) == [.codex])
assert(LiveTool.compact(codex: soloCodex, claude: joiningClaude, remaining: { $0 == .claude ? 0 : 40 }) == [.codex, .claude])
joiningClaude.hasRate = true
assert(LiveTool.visible(codex: soloCodex, claude: joiningClaude) == [.codex, .claude])
soloCodex.hasRate = false
assert(LiveTool.visible(codex: soloCodex, claude: joiningClaude) == [.claude])
let initial = MenuBarConfiguration()
assert(initial.order.filter { initial.enabled.contains($0) } == [.dial, .rate, .quota])
assert(initial.separator == "  " && initial.compact == false)
print("PASS: progressive tool visibility and dial/rate/quota default")

let existingMenu = MenuBarPreferences(defaults: defaults).configuration
let persistedCodex = Tachometer(tool: .codex, defaults: defaults)
let persistedClaude = Tachometer(tool: .claude, defaults: defaults)
persistedCodex.unit = .minute; persistedClaude.unit = .hour
persistedCodex.rawRate = 2; persistedClaude.rawRate = 3
persistedCodex.hasRate = true; persistedClaude.hasRate = true
persistedCodex.lastReport = now; persistedClaude.lastReport = now.addingTimeInterval(1)
assert(persistedCodex.displayedRate == 120 && persistedClaude.displayedRate == 10800)
assert(Tachometer(tool: .codex, defaults: defaults).unit == .minute)
assert(Tachometer(tool: .claude, defaults: defaults).unit == .hour)
assert(MenuBarPreferences(defaults: defaults).configuration == existingMenu, "Dashboard units cannot rewrite existing menu settings")
var follow = MenuBarConfiguration(); follow.enabled = [.rate]
assert(MenuBarPresentation.values(follow, meter: persistedCodex, monitor: monitor, now: now)[.rate] == "~120 tok/m")
assert(MenuBarPresentation.values(follow, meter: persistedClaude, monitor: monitor, now: now)[.rate]?.hasSuffix("tok/h") == true)
assert(MenuBarTool.auto.resolve(codex: persistedCodex, claude: persistedClaude) == .claude)
follow.unit = "s"
assert(MenuBarPresentation.values(follow, meter: persistedClaude, monitor: monitor, now: now)[.rate] == "~3 tok/s")
assert(persistedClaude.unit == .hour && persistedCodex.unit == .minute)
let fixedIdentity = MenuBarPresentation.attributed(follow, meter: persistedCodex, monitor: monitor, now: now, accent: .red, tool: .codex)
assert((fixedIdentity.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor) == NSColor.red)
let absent = MenuBarPresentation.values(follow, meter: persistedClaude, monitor: monitor, now: now, tool: .claude, claudeQuota: ToolQuotaState())
assert(absent[.quota] == "Claude quota unavailable" && absent[.zero] == "Zero —")
assert(Tachometer().unit == .second, "Unconfigured synthetic meters cannot read production preferences")
print("PASS: independent persisted dashboard units, inherited compact values, Auto selection, menu override, caller-selected identity color and missing quota")

let combinedCodex = Tachometer(), combinedClaude = Tachometer(), combinedGrok = Tachometer()
combinedCodex.hasRate = true; combinedCodex.rawRate = 20; combinedCodex.unit = .minute
combinedGrok.hasRate = true; combinedGrok.rawRate = 30; combinedGrok.unit = .hour
var combinedConfig = MenuBarConfiguration(); combinedConfig.enabled = [.rate, .quota]; combinedConfig.unit = "s"
var combinedPalette = ToolPalette(); combinedPalette.overrides["grok"] = .pink
let combined = MenuBarPresentation.combined(combinedConfig, codex: combinedCodex, claude: combinedClaude, grok: combinedGrok,
    monitor: monitor, now: now, palette: combinedPalette, claudeQuota: ToolQuotaState())
assert(combined.string.contains("Total") && combined.string.contains("~50 tok/s"))
assert(combined.string.contains("Codex") && !combined.string.contains("Grok quota unavailable"))
combinedConfig.tool = .grok
let onlyGrok = MenuBarPresentation.combined(combinedConfig, codex: combinedCodex, claude: combinedClaude, grok: combinedGrok,
    monitor: monitor, now: now, palette: combinedPalette, claudeQuota: ToolQuotaState())
assert(!onlyGrok.string.contains("Total") && onlyGrok.string.contains("~30 tok/s"))
assert(onlyGrok.string.hasPrefix("Grok") && onlyGrok.string.contains("Quota unavailable") && !onlyGrok.string.contains("40% remaining"))
let grokLabel = (onlyGrok.string as NSString).range(of: "Quota unavailable").location
assert((onlyGrok.attribute(.foregroundColor, at: grokLabel, effectiveRange: nil) as? NSColor) == NSColor(combinedPalette.color("grok", fallback: .green)))
assert(MenuBarPresentation.values(combinedConfig, meter: combinedGrok, monitor: monitor, now: now, tool: .grok)[.quota] == "Grok quota unavailable")
assert(LiveTool.visible(codex: combinedCodex, claude: combinedClaude, grok: combinedGrok) == [.codex, .grok])
print("PASS: combined rates, explicit Grok selection, tool-colored remaining labels and Grok quota isolation")

let idleCodex = Tachometer(), idleClaude = Tachometer(), openGrok = Tachometer()
openGrok.activity.turns["g"] = TaskActivity(turn: "g", started: now, observed: now, running: true, kind: .chat, session: "g", tool: .grok)
assert(openGrok.runningCount == 1 && !openGrok.hasRate)
assert(MenuBarTool.auto.resolve(codex: idleCodex, claude: idleClaude, grok: openGrok) == .grok)
var grokOnlyConfig = MenuBarConfiguration(); grokOnlyConfig.enabled = [.rate, .activity]
let grokOnly = MenuBarPresentation.combined(grokOnlyConfig, codex: idleCodex, claude: idleClaude, grok: openGrok,
    monitor: monitor, now: now, palette: ToolPalette(), claudeQuota: ToolQuotaState())
assert(grokOnly.string.hasPrefix("Grok"), "Auto must name Grok when it is the only active tool")
assert(!grokOnly.string.contains("Total") && !grokOnly.string.contains("Codex"))
let staleGrok = Tachometer()
staleGrok.activity.turns["g"] = TaskActivity(turn: "g", started: now.addingTimeInterval(-400), observed: now.addingTimeInterval(-400), running: true, kind: .chat, session: "g", tool: .grok)
assert(staleGrok.runningCount == 0 && staleGrok.activity.uncertain == 1)
assert(LiveTool.visible(codex: idleCodex, claude: idleClaude, grok: staleGrok).isEmpty)
assert(MenuBarTool.auto.resolve(codex: idleCodex, claude: idleClaude, grok: staleGrok) == .codex)
let unconfirmed = MenuBarPresentation.combined(grokOnlyConfig, codex: idleCodex, claude: idleClaude, grok: staleGrok,
    monitor: monitor, now: now, palette: ToolPalette(), claudeQuota: ToolQuotaState())
assert(!unconfirmed.string.contains("Codex") && !unconfirmed.string.contains("Grok"), "Stale Grok activity must not keep an inactive tool visible")
monitor.currentID = "a"
var autoGrokQuota = MenuBarConfiguration(); autoGrokQuota.enabled = [.rate, .quota]
let grokWithCodexQuota = MenuBarPresentation.combined(autoGrokQuota, codex: idleCodex, claude: idleClaude, grok: openGrok,
    monitor: monitor, now: now, palette: ToolPalette(), claudeQuota: ToolQuotaState())
assert(grokWithCodexQuota.string.hasPrefix("Grok") && !grokWithCodexQuota.string.contains("Codex 40% remaining"))
assert(!grokWithCodexQuota.string.contains("Grok quota unavailable"))
autoGrokQuota.tool = .grok
let explicitGrokQuota = MenuBarPresentation.combined(autoGrokQuota, codex: idleCodex, claude: idleClaude, grok: openGrok,
    monitor: monitor, now: now, palette: ToolPalette(), claudeQuota: ToolQuotaState())
assert(explicitGrokQuota.string.hasPrefix("Grok") && explicitGrokQuota.string.contains("Quota unavailable") && !explicitGrokQuota.string.contains("40% remaining"))
let grokReading = QuotaReading(accountID: "grok:x", bucket: "grok", name: "X Premium+", window: "weekly", minutes: 10080, used: 49, reset: now.addingTimeInterval(86400), date: now)
let grokState = ToolQuotaState(readings: [grokReading], samples: [grokReading])
assert(MenuBarPresentation.values(autoGrokQuota, meter: openGrok, monitor: monitor, now: now, tool: .grok, grokQuota: grokState)[.quota] == "Grok 51% remaining")
let grokMeasured = MenuBarPresentation.combined(autoGrokQuota, codex: idleCodex, claude: idleClaude, grok: openGrok,
    monitor: monitor, now: now, palette: ToolPalette(), claudeQuota: ToolQuotaState(), grokQuota: grokState)
assert(grokMeasured.string.hasPrefix("Grok") && grokMeasured.string.contains("51% remaining") && !grokMeasured.string.contains("quota unavailable"))
assert(!grokMeasured.string.contains("Codex 40% remaining"))
print("PASS: Auto menu bar follows Grok activity without a rate and without falling back to Codex")
print("PASS: Auto does not borrow unused Codex remaining beside Grok speed; explicit Grok does not inherit Codex quota")
let claudeSpent = QuotaReading(accountID: ClaudeQuotaSource.accountID("a"), bucket: "claude", name: "Claude", window: "five_hour", minutes: 300, used: 100, reset: now.addingTimeInterval(3600), date: now)
let claudeSpentState = ToolQuotaState(readings: [claudeSpent], samples: [claudeSpent], horizon: ClaudeQuotaSource.horizon)
var spentBar = MenuBarConfiguration(); spentBar.enabled = [.dial, .rate, .quota, .fable]
let spent = MenuBarPresentation.combined(spentBar, codex: idleCodex, claude: idleClaude, grok: staleGrok,
    monitor: monitor, now: now, palette: ToolPalette(), claudeQuota: claudeSpentState)
assert(spent.string.contains("Claude") && spent.string.contains("0% remaining"), spent.string)
assert(!spent.string.contains("Fable") && !spent.string.contains("Codex") && !spent.string.contains("tok/"), spent.string)
assert(LiveTool.compact(codex: idleCodex, claude: idleClaude, grok: staleGrok, remaining: { $0 == .claude ? 0 : nil }) == [.claude])
assert(LiveTool.compact(codex: idleCodex, claude: idleClaude, grok: staleGrok, remaining: { _ in 0 }) == [.claude])
let previousAccount = monitor.state.accounts["a"]
let spentCodex = QuotaReading(accountID: "a", bucket: "codex", name: "Codex", window: "primary", minutes: 10080, used: 100, reset: now.addingTimeInterval(3600), date: now)
monitor.state.accounts["a"] = LiveAccount(id: "a", email: "fixture", plan: "pro", observed: now, quotas: [spentCodex])
let grokSpent = QuotaReading(accountID: "grok:x", bucket: "grok", name: "X Premium+", window: "weekly", minutes: 10080, used: 100, reset: now.addingTimeInterval(86400), date: now)
var unusedZeroBar = MenuBarConfiguration(); unusedZeroBar.enabled = [.dial, .rate, .quota]
let unusedZeros = MenuBarPresentation.combined(unusedZeroBar, codex: idleCodex, claude: idleClaude, grok: staleGrok,
    monitor: monitor, now: now, palette: ToolPalette(), claudeQuota: ToolQuotaState(), grokQuota: ToolQuotaState(readings: [grokSpent], samples: [grokSpent]))
assert(!unusedZeros.string.contains("Codex") && !unusedZeros.string.contains("Grok") && !unusedZeros.string.contains("Claude"),
       "Idle unused zeros stay off Auto: \(unusedZeros.string)")
monitor.state.accounts["a"] = previousAccount
var unusedRemainingBar = MenuBarConfiguration(); unusedRemainingBar.enabled = [.dial, .rate, .quota]
let unusedRemaining = MenuBarPresentation.combined(unusedRemainingBar, codex: idleCodex, claude: idleClaude, grok: staleGrok,
    monitor: monitor, now: now, palette: ToolPalette(), claudeQuota: ToolQuotaState())
assert(!unusedRemaining.string.contains("Codex") && !unusedRemaining.string.contains("40%") && !unusedRemaining.string.contains("remaining"),
       "Unused remaining above zero stays off idle Auto: \(unusedRemaining.string)")
let workingCodex = Tachometer()
workingCodex.hasRate = true; workingCodex.rawRate = 12; workingCodex.rate = 12
let claudePlenty = QuotaReading(accountID: ClaudeQuotaSource.accountID("a"), bucket: "claude", name: "Claude",
                                window: "five_hour", minutes: 300, used: 40, reset: now.addingTimeInterval(3600), date: now)
let claudePlentyState = ToolQuotaState(readings: [claudePlenty], samples: [claudePlenty], horizon: ClaudeQuotaSource.horizon)
let workingWithUnusedClaude = MenuBarPresentation.combined(unusedRemainingBar, codex: workingCodex, claude: idleClaude, grok: staleGrok,
    monitor: monitor, now: now, palette: ToolPalette(), claudeQuota: claudePlentyState)
assert(workingWithUnusedClaude.string.hasPrefix("Codex") && !workingWithUnusedClaude.string.contains("Claude"),
       "Working Auto does not borrow unused Claude remaining: \(workingWithUnusedClaude.string)")
let workingWithClaudeZero = MenuBarPresentation.combined(unusedRemainingBar, codex: workingCodex, claude: idleClaude, grok: staleGrok,
    monitor: monitor, now: now, palette: ToolPalette(), claudeQuota: claudeSpentState)
assert(workingWithClaudeZero.string.hasPrefix("Codex") && !workingWithClaudeZero.string.contains("Claude"),
       "Claude-at-zero occupies idle Auto only, not a second working-line occupant: \(workingWithClaudeZero.string)")
assert(LiveTool.compact(codex: workingCodex, claude: idleClaude, grok: staleGrok, remaining: { $0 == .claude ? 0 : 40 }) == [.codex, .claude])
assert(LiveTool.compact(codex: workingCodex, claude: idleClaude, grok: staleGrok, remaining: { $0 == .claude ? 40 : 40 }) == [.codex])
print("PASS: idle Auto names a measured-zero Claude remaining and keeps unused Codex and Fable off the bar")
print("PASS: unused remaining cannot occupy Auto; Claude-at-zero is an idle exception, not a working-line occupant")
let exhausted = Runway.estimate(QuotaReading(accountID: "a", bucket: "codex", name: "Codex", window: "primary", minutes: 10080, used: 100, reset: now.addingTimeInterval(3600), date: now), samples: [], now: now)
assert(CompactLiveCopy.rate(true, amount: 7680, unit: .minute) == "~7.7k tok/m")
assert(CompactLiveCopy.rate(false, amount: 0, unit: .second) == "—")
assert(CompactLiveCopy.remaining(exhausted) == "0%")
assert(CompactLiveCopy.remaining(nil) == "—")
assert(CompactLiveCopy.detail(reading: nil, estimate: nil, now: now) == "Unavailable")
assert(CompactLiveCopy.detail(reading: QuotaReading(accountID: "a", bucket: "codex", name: "Codex", window: "primary", minutes: 10080, used: 100, reset: now.addingTimeInterval(86400), date: now), estimate: exhausted, now: now).contains("Exhausted"))
print("PASS: compact popover remaining copy stays short and does not invent a figure")

// Auto and explicit menu paths must consume the same single accent, even with
// legacy blue/orange overrides present. Ordinary labels remain system-colored.
let oneAccent = AppearancePreferences.color("D5F566")
let competing = ToolPalette(overrides: ["codex": .blue, "claude": .orange], followsAccent: false, accent: oneAccent)
let themeCodex = Tachometer(), themeClaude = Tachometer(), themeGrok = Tachometer()
themeCodex.hasRate = true; themeClaude.hasRate = true
for selection in MenuBarTool.allCases {
    var themeSettings = MenuBarConfiguration()
    themeSettings.tool = selection
    themeSettings.enabled = [.icon, .quota, .rate]
    let text = MenuBarPresentation.combined(themeSettings, codex: themeCodex, claude: themeClaude, grok: themeGrok,
        monitor: monitor, now: now, palette: competing, claudeQuota: ToolQuotaState())
    var accentRuns = 0
    text.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text.length)) { value, _, _ in
        guard let color = value as? NSColor else { return }
        assert(color == NSColor(oneAccent) || color == .labelColor, "Menu introduced another accent")
        if color == NSColor(oneAccent) { accentRuns += 1 }
    }
    assert(accentRuns > 0, "Every menu selection retains the chosen accent")
}
print("PASS: Auto and every selected tool preserve exactly one menu accent despite legacy overrides")

// Names belong to the composed single-tool readout, not each configurable field.
// Exercise every enabled-field subset, both densities and both order directions.
for selection in [MenuBarTool.codex, .claude, .grok, .auto] {
    let label = selection == .claude ? "Claude" : selection == .grok ? "Grok" : "Codex"
    for compact in [false, true] {
        for reverse in [false, true] {
            for mask in 0..<(1 << MenuBarPart.allCases.count) {
                var choice = MenuBarConfiguration()
                choice.tool = selection; choice.compact = compact
                choice.order = reverse ? Array(MenuBarPart.allCases.reversed()) : MenuBarPart.allCases
                choice.enabled = Set(MenuBarPart.allCases.enumerated().filter { mask & (1 << $0.offset) != 0 }.map { $0.element })
                for date in [now, now.addingTimeInterval(121)] {
                    let composed = MenuBarPresentation.combined(choice, codex: idleCodex, claude: idleClaude, grok: staleGrok,
                        monitor: monitor, now: date, palette: combinedPalette, claudeQuota: ToolQuotaState(), grokQuota: grokState)
                    if selection == .auto {
                        assert(!composed.string.contains("Codex") && !composed.string.contains("Claude") && !composed.string.contains("Grok"),
                               "Idle Auto does not invent a tool: \(composed.string)")
                        assert(!composed.string.contains("Fable"), "Idle Auto omits unused Fable copy: \(composed.string)")
                    } else {
                        let expected = label
                        assert(composed.string.components(separatedBy: expected).count - 1 == 1,
                               "One tool label per readout: \(composed.string)")
                    }
                    let plain = MenuBarPresentation.title(choice, meter: idleCodex, monitor: monitor, now: date, tool: .codex)
                    assert(plain.components(separatedBy: "Codex").count - 1 == 1, "Plain titles follow the same identity rule")
                }
            }
        }
    }
}
print("PASS: every field subset, compactness and order direction names the selected tool exactly once, including stale quota")

// Speed panels have no idle fallback; independent account allowances persist.
assert(LiveTool.active(codex: idleCodex, claude: idleClaude, grok: staleGrok).isEmpty)
assert(LiveTool.active(codex: idleCodex, claude: idleClaude, grok: openGrok) == [.grok])
openGrok.activity.turns["g"]?.running = false
openGrok.tick(now: now)
assert(LiveTool.active(codex: idleCodex, claude: idleClaude, grok: openGrok).isEmpty)
joiningClaude.hasRate = true
assert(LiveTool.active(codex: idleCodex, claude: joiningClaude, grok: staleGrok) == [.claude])
joiningClaude.hasRate = false
assert(LiveTool.active(codex: idleCodex, claude: joiningClaude, grok: staleGrok).isEmpty)
print("PASS: live panels admit fresh activity, exclude stale providers, and remove stopped tools")

// Provider-scoped failures survive filtering without becoming working activity.
let recoveringClaude = Tachometer()
var failedFeed = ActivitySnapshot(readAt: now, toolErrors: [.claude: "Synthetic transcript read failed"], referenceDate: now)
recoveringClaude.activity = failedFeed.filtered(for: .claude)
recoveringClaude.tick(now: now)
assert(recoveringClaude.activity.error == "Synthetic transcript read failed")
assert(failedFeed.filtered(for: .grok).error == nil)
assert(LiveTool.active(codex: idleCodex, claude: recoveringClaude).isEmpty)
var healthyFeed = ActivitySnapshot(readAt: now, referenceDate: now)
healthyFeed.turns["recovered"] = TaskActivity(turn: "recovered", started: now, observed: now, running: true, kind: .chat, session: "recovered", tool: .claude)
healthyFeed.measurements["recovered"] = RateMeasurement(turn: "recovered", date: now, duration: 2, output: 40, model: "synthetic-claude")
recoveringClaude.activity = healthyFeed.filtered(for: .claude)
recoveringClaude.tick(now: now)
assert(recoveringClaude.activity.error == nil && recoveringClaude.hasRate && recoveringClaude.rawRate == 20)
assert(LiveTool.active(codex: idleCodex, claude: recoveringClaude) == [.claude])
print("PASS: Claude error-only state remains independent of active selection and clears on fresh recovery")

// A crossfade blends two snapshots in place. It reads as one line only when every glyph keeps its
// position; a variable-length status item that changes width must swap instantly instead.
do {
    let digits = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    func line(_ position: Double, _ text: String, font: NSFont? = nil) -> NSAttributedString {
        let value = NSMutableAttributedString(attributedString: MenuBarDial.attributed(value: position, minimum: 0, maximum: 1, available: true, accent: .labelColor, identity: "claude"))
        value.append(NSAttributedString(string: text, attributes: [.font: font ?? digits]))
        return value
    }
    let tail = "  2% remaining  Fable 0% · Fable week"
    let steady = line(0.4, "~98 tok/s" + tail)
    assert(MenuBarValueAnimator.alignsForCrossfade(steady, line(0.5, "~97 tok/s" + tail)), "Same-width digit changes keep the crossfade")
    assert(!MenuBarValueAnimator.alignsForCrossfade(steady, line(0.5, "~104 tok/s" + tail)), "A digit-count change shifts everything after it")
    assert(!MenuBarValueAnimator.alignsForCrossfade(line(0.4, "~98 tok/s  2% remaining"), line(0.4, "~98 tok/s  9% remaining  Zero 12:40")), "A longer line never crossfades")
    assert(!MenuBarValueAnimator.alignsForCrossfade(line(0.4, "Fable 0% · 5h"), line(0.4, "Fable 0% · wk")), "Changed words never crossfade, even at equal length")
    let proportional = NSFont.systemFont(ofSize: 12)
    assert(!MenuBarValueAnimator.alignsForCrossfade(line(0.4, "Claude 11%", font: proportional), line(0.4, "Claude 88%", font: proportional)), "Proportional digits that change width do not crossfade")
    _ = NSApplication.shared
    let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    // Core Animation files every CATransition under kCATransition, whatever key it was added with.
    let shifting = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 22))
    let animator = MenuBarValueAnimator()
    animator.update(steady, in: shifting, reduceMotion: false) { _ in }
    animator.update(line(0.6, "~104 tok/s" + tail), in: shifting, reduceMotion: false) { _ in }
    assert(shifting.layer != nil && shifting.layer?.animation(forKey: kCATransition) == nil, "A width change must not blend two misaligned lines")
    assert(reduced || animator.isAnimating, "The dial still moves when the text swaps instantly")
    animator.cancel()
    if !reduced {
        let aligned = NSView(frame: shifting.frame)
        let crossfading = MenuBarValueAnimator()
        crossfading.update(steady, in: aligned, reduceMotion: false) { _ in }
        crossfading.update(line(0.6, "~97 tok/s" + tail), in: aligned, reduceMotion: false) { _ in }
        assert(aligned.layer?.animation(forKey: kCATransition) != nil, "Glyph-aligned digit changes keep the designed crossfade")
        crossfading.cancel()
    }
    print("PASS: menu-bar crossfade only between glyph-aligned lines; width or word changes swap instantly while the dial still moves")
}
// Animation changes presentation only, including when units and selected tools change.
do {
    func presentation(_ position: Double, _ text: String, id: String = "codex", available: Bool = true) -> NSAttributedString {
        let value = NSMutableAttributedString(attributedString: MenuBarDial.attributed(value: position, minimum: 0, maximum: 1, available: available, accent: .labelColor, identity: id))
        value.append(NSAttributedString(string: text))
        return value
    }
    let first = presentation(0.2, "Codex ~20 tok/s")
    let next = presentation(0.8, "Codex ~4.8k tok/m")
    let halfway = MenuBarValueAnimator.frame(from: first, to: next, progress: 0.5)
    assert(halfway.string == next.string, "Interpolated dial must never invent an intermediate count or unit")
    assert(abs((halfway.attribute(MenuBarDial.position, at: 0, effectiveRange: nil) as! Double) - 0.5) < 0.001)
    let other = presentation(0.9, "Claude ~90 tok/s", id: "claude")
    assert(MenuBarValueAnimator.signature(MenuBarValueAnimator.frame(from: first, to: other, progress: 0)).isEqual(to: MenuBarValueAnimator.signature(other)), "New tools never inherit another tool's needle")
    let missing = presentation(0, "Codex — tok/s", available: false)
    assert(MenuBarValueAnimator.signature(MenuBarValueAnimator.frame(from: first, to: missing, progress: 0.5)).isEqual(to: MenuBarValueAnimator.signature(missing)), "Unavailable data cannot retain an animated measurement")
    assert(MenuBarValueAnimator.signature(first).isEqual(to: MenuBarValueAnimator.signature(presentation(0.2, "Codex ~20 tok/s"))), "Fresh image objects do not cause unchanged-value animation")
    _ = NSApplication.shared
    let field = NSTextField(labelWithString: "")
    let animator = MenuBarValueAnimator()
    var applied = 0
    func apply(_ value: NSAttributedString) { field.attributedStringValue = value; applied += 1 }
    animator.update(first, in: field, reduceMotion: false, apply: apply)
    animator.update(next, in: field, reduceMotion: false, apply: apply)
    assert(field.stringValue == next.string)
    animator.update(other, in: field, reduceMotion: true, apply: apply)
    assert(!animator.isAnimating && field.stringValue == other.string, "Reduced motion immediately finishes and cancels pending updates")
    let settled = applied
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    assert(applied == settled, "Cancelled timers cannot restore an obsolete value")
    animator.update(first, in: field, reduceMotion: false, apply: apply)
    let deadline = Date().addingTimeInterval(1)
    while animator.isAnimating && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    assert(!animator.isAnimating && MenuBarValueAnimator.signature(animator.displayed!).isEqual(to: MenuBarValueAnimator.signature(first)))
    let finalCount = applied
    animator.update(presentation(0.2, "Codex ~20 tok/s"), in: field, reduceMotion: false, apply: apply)
    assert(applied == finalCount, "Settled values perform no redraw or timer work")
    let detached = MenuBarValueAnimator()
    weak var disappearing: NSView?
    autoreleasepool {
        let view = NSView(); disappearing = view
        detached.update(first, in: view, reduceMotion: false) { _ in }
        detached.update(next, in: view, reduceMotion: false) { _ in }
    }
    assert(disappearing == nil, "The fixture must release AppKit's autoreleased view before testing owner cleanup")
    RunLoop.main.run(until: Date().addingTimeInterval(0.08))
    assert(!detached.isAnimating, "Releasing a presentation owner cancels its animation timer")
    var compactSettings = MenuBarConfiguration(); compactSettings.compact = true
    assert(MenuBarPresentation.values(compactSettings, meter: meter, monitor: monitor, now: now)[.rate]!.contains(" tok/"))
}
print("PASS: native menu animation preserves measured text/units, tool identity, missing values, reduced motion, retargeting and timer cleanup")

// Account relevance survives the meter window, retaining identities, never payloads.
do {
    var relevance = AccountToolRelevance()
    assert(relevance.tools.isEmpty)
    relevance.observe(.grok) // A default home, enabled monitor, or initial error is no evidence.
    assert(relevance.tools.isEmpty)
    relevance.observe(.claude, discovered: true)
    relevance.observe(.codex, quota: true)
    relevance.observe(.grok, account: true)
    assert(relevance.tools == [.codex, .claude, .grok])
    for tool in LiveTool.allCases { relevance.observe(tool) }
    assert(relevance.tools == [.codex, .claude, .grok], "Idle, stale and failed updates cannot erase known tools")
    var activeOnly = AccountToolRelevance()
    activeOnly.observe(.claude, activity: true)
    activeOnly.observe(.claude)
    assert(activeOnly.tools == [.claude])
    let reading = QuotaReading(accountID: "synthetic-a", bucket: "codex", name: "Account", window: "primary", minutes: 300,
                               used: 36, reset: now.addingTimeInterval(3600), date: now)
    let current = ToolQuotaState(readings: [reading], accountLabel: "Synthetic account", guardAccountID: "synthetic-a")
    let shown = AccountAllowancePresentation(quota: current, now: now)
    assert(shown.remaining == "64%" && shown.qualifier == "Remaining")
    assert(shown.detail.contains("Resets") && shown.detail.contains("Quota read") && shown.detail.contains("Synthetic account"))
    assert(shown.detail.contains("Learning quota burn"), "Insufficient slope remains explicit")
    var exhaustedQuota = current; exhaustedQuota.readings[0].used = 100
    let empty = AccountAllowancePresentation(quota: exhaustedQuota, now: now)
    assert(empty.remaining == "0%" && empty.qualifier == "Exhausted")
    var stale = current; stale.readings[0].date = now.addingTimeInterval(-3600)
    assert(AccountAllowancePresentation(quota: stale, now: now).remaining == "—")
    assert(AccountAllowancePresentation(quota: stale, now: now).detail.contains("Stale"))
    var expired = current; expired.readings[0].reset = now
    assert(AccountAllowancePresentation(quota: expired, now: now).remaining == "—")
    assert(AccountAllowancePresentation(quota: expired, now: now).qualifier.contains("Reset passed"))
    var failed = current; failed.guardFailed = true
    assert(AccountAllowancePresentation(quota: failed, now: now).remaining == "—")
    assert(AccountAllowancePresentation(quota: failed, now: now).detail.contains("Read failed"))
    var switched = current; switched.guardAccountID = "synthetic-b"; switched.accountLabel = "Second synthetic account"
    let switchedFace = AccountAllowancePresentation(quota: switched, now: now)
    assert(switchedFace.reading == nil && switchedFace.remaining == "—")
    assert(!switchedFace.detail.contains("64%"), "Old account allowance cannot be labeled as the new account")
    var invalid = current; invalid.readings[0].used = -1
    assert(AccountAllowancePresentation(quota: invalid, now: now).remaining == "—")
    print("PASS: account relevance survives idle/failure with stable order; allowance preserves reset/freshness/identity/zero boundaries")
}
assert(CompactLiveCopy.activity(idleCodex) == "Unconfirmed", "No source read is not proof of idle")
idleCodex.activity = ActivitySnapshot(readAt: now, referenceDate: now)
assert(CompactLiveCopy.activity(idleCodex) == "Idle")
assert(CompactLiveCopy.activity(recoveringClaude) == "Working")
recoveringClaude.hasRate = false
assert(CompactLiveCopy.activity(recoveringClaude) == "Working", "Working without speed remains working")
recoveringClaude.activity = failedFeed.filtered(for: .claude); recoveringClaude.tick(now: now)
assert(CompactLiveCopy.activity(recoveringClaude) == "Unconfirmed")
print("PASS: compact activity distinguishes working without rate, idle and unconfirmed")

// Accounts & plans hides only the provider's Spark bucket, without changing evidence.
do {
    let codex = QuotaReading(accountID: "sample", bucket: "codex", name: "Codex", window: "primary", minutes: 300,
                             used: 36, reset: now.addingTimeInterval(3600), date: now)
    var spark = codex; spark.bucket = "codex_bengalfox"; spark.name = "GPT-5.3-Codex-Spark"
    var weekly = spark; weekly.window = "secondary"; weekly.minutes = 10080
    var renamed = spark; renamed.name = "Provider renamed allowance"
    var unrelated = codex; unrelated.bucket = "future_spark_bucket"; unrelated.name = "Sparkling future allowance"
    let account = LiveAccount(id: "sample", email: "sample@example.com", plan: "pro", observed: now,
                              quotas: [spark, codex, weekly, renamed, unrelated])
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let stored = try! encoder.encode(account)
    assert(AccountQuotaPresentation.visible(account.quotas) == [codex, unrelated])
    assert(AccountQuotaPresentation.visible([spark, weekly]).isEmpty)
    assert(AccountQuotaPresentation.visible([]).isEmpty)
    assert(try! encoder.encode(account) == stored, "Presentation must preserve stored quota evidence")
    print("PASS: Accounts & plans omits exact Spark bucket in both windows, preserves unrelated allowances and raw observations")
}

// Model-scoped weekly windows and the Fable roll-up: the tightest current limit, named, never a sum.
func claudeLimitsCache(session: Double = 32, week: Double = 8, fable: Double? = 8, model: String = "Fable",
                       at base: Date = cacheNow, age: Double = 0, fableReset: Double = 6 * 86400, rawLimits: Any? = nil) throws -> Data {
    let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    // Claude Code writes microsecond fractions with a numeric offset.
    func stamp(_ offset: Double) -> String { String(iso.string(from: base.addingTimeInterval(offset)).dropLast()) + "456+00:00" }
    var limits: [[String: Any]] = [["kind": "session", "group": "session", "percent": session, "resets_at": stamp(14400), "scope": NSNull()],
                                   ["kind": "weekly_all", "group": "weekly", "percent": week, "resets_at": stamp(6 * 86400), "scope": NSNull()]]
    if let fable {
        limits.append(["kind": "weekly_scoped", "group": "weekly", "percent": fable, "resets_at": stamp(fableReset),
                       "scope": ["model": ["id": NSNull(), "display_name": model], "surface": NSNull()]])
    }
    let utilization: [String: Any] = ["five_hour": ["utilization": session, "resets_at": stamp(14400)],
                                      "seven_day": ["utilization": week, "resets_at": stamp(6 * 86400)],
                                      "limits": rawLimits ?? limits]
    return try JSONSerialization.data(withJSONObject: ["oauthAccount": ["accountUuid": "a"],
        "cachedUsageUtilization": ["accountUuid": "a", "fetchedAtMs": base.addingTimeInterval(-age).timeIntervalSince1970 * 1000, "utilization": utilization]])
}
func claudeState(_ data: Data, now date: Date = cacheNow) throws -> ToolQuotaState {
    let cache = try JSONDecoder().decode(ClaudeQuotaCache.self, from: data)
    let readings = cache.readings(now: date)
    return ToolQuotaState(readings: readings, samples: readings, horizon: ClaudeQuotaSource.horizon,
                          guardAccountID: readings.first?.accountID, guardAuthenticated: readings.first != nil, scoped: cache.scopedReadings(now: date))
}
do {
    typealias Budget = ClaudeQuotaSource.FableBudget
    let bound = try claudeState(try claudeLimitsCache())
    assert(bound.readings.map(\.window) == ["five_hour", "seven_day"], "Scoped windows never join the prioritized Claude allowance or Quota Guard")
    assert(bound.scoped.count == 1 && bound.scoped[0].window == ClaudeQuotaSource.fableWindow && bound.scoped[0].used == 8 && bound.scoped[0].minutes == 10080)
    assert(abs(bound.scoped[0].reset.timeIntervalSince(cacheNow.addingTimeInterval(6 * 86400))) < 0.01, "Microsecond reset stamps parse")
    // Assertions evaluate lazily and cannot throw, so fixtures are decoded first.
    let weekBinds = try claudeState(try claudeLimitsCache(session: 10, week: 40, fable: 20))
    let fableBinds = try claudeState(try claudeLimitsCache(session: 10, week: 40, fable: 75))
    let fableExhausted = try claudeState(try claudeLimitsCache(fable: 100))
    let noFable = try claudeState(try claudeLimitsCache(fable: nil))
    let otherModel = try claudeState(try claudeLimitsCache(model: "Sonnet"))
    assert(ClaudeQuotaSource.fableBudget(bound, now: cacheNow) == Budget(remaining: 68, binding: "5h"))
    assert(ClaudeQuotaSource.fableBudget(weekBinds, now: cacheNow) == Budget(remaining: 60, binding: "week"))
    assert(ClaudeQuotaSource.fableBudget(fableBinds, now: cacheNow) == Budget(remaining: 25, binding: "Fable week"))
    assert(ClaudeQuotaSource.fableBudget(fableExhausted, now: cacheNow) == Budget(remaining: 0, binding: "Fable week"), "Exhaustion is a measured zero")
    // Missing, other-model, stale, reset, switched or failed inputs leave the budget unknown.
    assert(ClaudeQuotaSource.fableBudget(noFable, now: cacheNow) == nil)
    assert(ClaudeQuotaSource.fableBudget(otherModel, now: cacheNow) == nil)
    assert(ClaudeQuotaSource.fableBudget(bound, now: cacheNow.addingTimeInterval(ClaudeQuotaSource.horizon)) == nil)
    let resetting = try claudeState(try claudeLimitsCache(fableReset: 60))
    assert(ClaudeQuotaSource.fableBudget(resetting, now: cacheNow) != nil && ClaudeQuotaSource.fableBudget(resetting, now: cacheNow.addingTimeInterval(60)) == nil)
    var switchedAccount = bound; switchedAccount.guardAccountID = ClaudeQuotaSource.accountID("b")
    assert(ClaudeQuotaSource.fableBudget(switchedAccount, now: cacheNow) == nil)
    var failedRead = bound; failedRead.guardFailed = true
    assert(ClaudeQuotaSource.fableBudget(failedRead, now: cacheNow) == nil)
    let malformed = try claudeState(try claudeLimitsCache(rawLimits: [["kind": "weekly_scoped", "percent": "high"]]))
    assert(malformed.readings.count == 2 && malformed.scoped.isEmpty, "A malformed limits list drops only scoped readings")
    // The field names Fable rather than a tool, so single-tool identity and the one-accent rule still hold.
    var fableMenu = MenuBarConfiguration(); fableMenu.enabled = [.rate, .fable]
    assert(!MenuBarConfiguration().enabled.contains(.fable), "Fable quota is opt-in; default and saved selections are unchanged")
    assert(MenuBarPresentation.values(fableMenu, meter: meter, monitor: monitor, now: cacheNow, claudeQuota: bound)[.fable] == "Fable 68% · 5h")
    assert(MenuBarPresentation.values(fableMenu, meter: meter, monitor: monitor, now: cacheNow)[.fable] == "")
    assert(MenuBarPresentation.values(fableMenu, meter: meter, monitor: monitor, now: cacheNow, claudeQuota: noFable)[.fable] == "")
    assert(MenuBarPresentation.values(fableMenu, meter: meter, monitor: monitor, now: cacheNow, claudeQuota: fableExhausted)[.fable] == "",
           "A measured Fable zero does not occupy the status item")
    fableMenu.tool = .codex
    let codexWithFable = MenuBarPresentation.combined(fableMenu, codex: combinedCodex, claude: combinedClaude, grok: combinedGrok,
        monitor: monitor, now: cacheNow, palette: ToolPalette(), claudeQuota: bound)
    assert(codexWithFable.string.hasPrefix("Codex") && codexWithFable.string.hasSuffix("Fable 68% · 5h"), codexWithFable.string)
    fableMenu.tool = .auto
    let totalWithFable = MenuBarPresentation.combined(fableMenu, codex: combinedCodex, claude: combinedClaude, grok: combinedGrok,
        monitor: monitor, now: cacheNow, palette: ToolPalette(), claudeQuota: bound)
    assert(totalWithFable.string.hasPrefix("Total") && totalWithFable.string.components(separatedBy: "Fable 68% · 5h").count == 2, totalWithFable.string)
    fableMenu.enabled = [.rate, .quota, .fable, .fablePace]
    let idleWithFable = MenuBarPresentation.combined(fableMenu, codex: idleCodex, claude: idleClaude, grok: staleGrok,
        monitor: monitor, now: cacheNow, palette: ToolPalette(), claudeQuota: bound)
    assert(!idleWithFable.string.contains("Fable") && !idleWithFable.string.contains("Codex") && !idleWithFable.string.contains("Claude")
           && !idleWithFable.string.contains("remaining"),
           "Idle Auto omits unused Fable remaining: \(idleWithFable.string)")
    print("PASS: Claude model-scoped weekly rows, microsecond resets and the Fable tightest-limit roll-up across selections; missing or stale inputs stay unavailable")
}

// Installed Claude Code usage refresh: one quiet request per quarter hour, a bounded child, and cache-only trust.
do {
    assert(ClaudeUsageRefresh.interval == 900)
    assert(ClaudeUsageRefresh.isDue(lastAttempt: nil, now: cacheNow))
    assert(!ClaudeUsageRefresh.isDue(lastAttempt: cacheNow.addingTimeInterval(-899), now: cacheNow))
    assert(ClaudeUsageRefresh.isDue(lastAttempt: cacheNow.addingTimeInterval(-900), now: cacheNow))
    assert(ClaudeUsageRefresh.isDue(lastAttempt: cacheNow.addingTimeInterval(60), now: cacheNow), "A clock rollback cannot suppress the refresh")
    let arguments = ClaudeUsageRefresh.arguments
    assert(["-p", "--no-session-persistence", "--strict-mcp-config", "--disable-slash-commands"].allSatisfy { arguments.contains($0) })
    assert(arguments.firstIndex(of: "--setting-sources").map { arguments[$0 + 1] } == "project", "No user settings, hooks or plugins load")
    assert(ClaudeUsageRefresh.environment(["DISABLE_TELEMETRY": "0", "HOME": "/h"]) ==
           ["DISABLE_TELEMETRY": "1", "DISABLE_AUTOUPDATER": "1", "DISABLE_ERROR_REPORTING": "1", "HOME": "/h"])
    let request = try JSONSerialization.jsonObject(with: ClaudeUsageRefresh.request(id: "r1")) as! [String: Any]
    let body = request["request"] as! [String: Any]
    assert(request["type"] as? String == "control_request" && request["request_id"] as? String == "r1")
    assert(body["subtype"] as? String == "get_usage" && body["skip_behaviors"] as? Bool == true && body.count == 2, "No prompt or other control request is sent")
    func response(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: ["type": "control_response", "response": object]) }
    assert(ClaudeUsageRefresh.outcome(response(["subtype": "success", "request_id": "r1"]), id: "r1") == .success)
    assert(ClaudeUsageRefresh.outcome(response(["subtype": "success", "request_id": "r2"]), id: "r1") == nil)
    assert(ClaudeUsageRefresh.outcome(response(["subtype": "error", "request_id": "r1", "error": "Not logged in"]), id: "r1") == .failure("Not logged in"))
    assert(ClaudeUsageRefresh.outcome(Data("{\"type\":\"system\"}".utf8), id: "r1") == nil && ClaudeUsageRefresh.outcome(Data("noise".utf8), id: "r1") == nil)
    assert(ClaudeUsageRefresh.executable(environment: ["CLAUDE_CLI_PATH": "/missing/claude", "PATH": "/bin"], isExecutable: { _ in false }) == nil)
    assert(ClaudeUsageRefresh.executable(environment: ["PATH": "/one:/two"], userHome: URL(fileURLWithPath: "/home"), isExecutable: { $0 == "/two/claude" }) == "/two/claude")
    assert(ClaudeUsageRefresh.executable(environment: ["PATH": "/usr/bin"], userHome: URL(fileURLWithPath: "/home"), isExecutable: { $0 == "/home/.local/bin/claude" }) == "/home/.local/bin/claude",
           "A GUI launch's short PATH still finds the native installer location")

    // Synthetic executables prove the process boundary without contacting a provider.
    let processRoot = FileManager.default.temporaryDirectory.appendingPathComponent("tokenbar-claude-refresh-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: processRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: processRoot) }
    func fakeClaude(_ name: String, _ body: String) throws -> String {
        let url = processRoot.appendingPathComponent(name)
        try Data(("#!/bin/sh\n" + body).utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }
    let record = processRoot.appendingPathComponent("invocation")
    let answer = """
        printf '%s|%s|%s\\n' "$(pwd -P)" "$DISABLE_AUTOUPDATER" "$*" > '\(record.path)'
        IFS= read -r line
        id=$(printf '%s' "$line" | sed -E 's/.*"request_id":"([^"]+)".*/\\1/')
        printf '{"type":"system","subtype":"init"}\\n'
        printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":{}}}\\n' "$id"
        cat >/dev/null

        """
    let work = processRoot.appendingPathComponent("work")
    let quiet = ["PATH": "/usr/bin:/bin"]
    try ClaudeUsageRefresh.run(executable: try fakeClaude("answers", answer), directory: work, environment: quiet)
    let invocation = try String(contentsOf: record, encoding: .utf8).trimmingCharacters(in: .newlines).components(separatedBy: "|")
    assert(invocation.count == 3 && invocation[0].hasSuffix(processRoot.lastPathComponent + "/work") && invocation[1] == "1"
           && invocation[2] == arguments.joined(separator: " "), invocation.joined(separator: "|"))
    let workMode = (try FileManager.default.attributesOfItem(atPath: work.path)[.posixPermissions] as? NSNumber)?.intValue
    assert(workMode == 0o700, "The working directory is private")
    let refusing = try fakeClaude("refuses", """
        IFS= read -r line
        id=$(printf '%s' "$line" | sed -E 's/.*"request_id":"([^"]+)".*/\\1/')
        printf '{"type":"control_response","response":{"subtype":"error","request_id":"%s","error":"Not logged in"}}\\n' "$id"

        """)
    func failure(_ executable: String, timeout: TimeInterval = 5) -> String? {
        do { try ClaudeUsageRefresh.run(executable: executable, directory: work, environment: quiet, timeout: timeout); return nil }
        catch { return error.localizedDescription }
    }
    let exiting = try fakeClaude("exits", "exit 0\n"), silent = try fakeClaude("silent", "exec sleep 30\n")
    assert(failure(refusing) == "Not logged in")
    assert(failure(exiting) != nil, "An early exit is an error, never SIGPIPE")
    let started = Date()
    assert(failure(silent, timeout: 1) == "Claude Code usage refresh timed out")
    assert(Date().timeIntervalSince(started) < 5, "A silent child is terminated at the deadline")

    // The monitor asks the installed tool, then trusts only the account-bound cache that tool rewrote.
    func settle(_ done: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !done() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
    let cacheURL = processRoot.appendingPathComponent("claude.json"), relayURL = processRoot.appendingPathComponent("relay.json")
    let fresh = processRoot.appendingPathComponent("fresh.json")
    try claudeLimitsCache(at: Date(), age: 7200).write(to: cacheURL)
    try claudeLimitsCache(session: 20, week: 30, fable: 45, at: Date()).write(to: fresh)
    let rewriting = try fakeClaude("rewrites", "cp '\(fresh.path)' '\(cacheURL.path)'\n" + answer)
    let claudeMonitor = ClaudeQuotaMonitor(cacheURL: cacheURL, relayURL: relayURL, refreshDirectory: work, executable: { rewriting })
    claudeMonitor.refresh()
    settle { claudeMonitor.quota.unavailable != "Awaiting fresh Claude quota" }
    let refreshed = ClaudeQuotaSource.fableBudget(claudeMonitor.quota, now: Date())
    assert(claudeMonitor.refreshFailure == nil && refreshed == ClaudeQuotaSource.FableBudget(remaining: 55, binding: "Fable week"), String(describing: refreshed))
    try claudeLimitsCache(at: Date(), age: 7200).write(to: cacheURL)
    claudeMonitor.refresh()
    settle { claudeMonitor.quota.scoped.isEmpty }
    assert(claudeMonitor.quota.scoped.isEmpty && claudeMonitor.quota.readings.isEmpty, "Within the quarter hour the cache is reread without starting Claude Code again")
    let failing = ClaudeQuotaMonitor(cacheURL: cacheURL, relayURL: relayURL, refreshDirectory: work, executable: { refusing })
    failing.refresh()
    settle { failing.refreshFailure != nil }
    assert(failing.refreshFailure == "Not logged in" && failing.quota.unavailable.hasSuffix("Claude Code usage refresh failed: Not logged in"))
    var asked = false
    let preview = ClaudeQuotaMonitor(cacheURL: cacheURL, relayURL: relayURL, executable: { asked = true; return rewriting })
    preview.refresh()
    settle { preview.quota.unavailable != "Awaiting fresh Claude quota" }
    assert(!asked, "Previews and fixtures never start Claude Code")
    print("PASS: installed Claude Code refresh sends one quiet get_usage request per quarter hour, bounds the child, reports failures and trusts only the rewritten account-bound cache")
}

// Fable time left: averaged recent burn per limit, not the latest slope, and never a partial projection.
do {
    typealias Pace = ClaudeQuotaSource.FablePace
    let account = ClaudeQuotaSource.accountID("a")
    /// The three Fable limits sampled together at a fixed step, oldest first; the last value is current.
    func paced(session: [Double], week: [Double], fable: [Double], step: Double = 900, sessionReset: Double = 4 * 3600,
               resetJitter: Double = 0) -> ToolQuotaState {
        func series(_ window: String, _ values: [Double], minutes: Int, reset: Double) -> [QuotaReading] {
            values.enumerated().map { index, used in
                QuotaReading(accountID: account, bucket: "claude", name: "Claude", window: window, minutes: minutes, used: used,
                             reset: cacheNow.addingTimeInterval(reset + (index % 2 == 0 ? 0 : resetJitter)),
                             date: cacheNow.addingTimeInterval(-Double(values.count - 1 - index) * step))
            }
        }
        let s = series("five_hour", session, minutes: 300, reset: sessionReset)
        let w = series("seven_day", week, minutes: 10080, reset: 6 * 86400)
        let f = series(ClaudeQuotaSource.fableWindow, fable, minutes: 10080, reset: 6 * 86400)
        return ToolQuotaState(readings: [s[s.count - 1], w[w.count - 1]], horizon: ClaudeQuotaSource.horizon, guardAccountID: account,
                              guardAuthenticated: true, scoped: [f[f.count - 1]], paceHistory: s + w + f)
    }
    func left(_ pace: Pace?) -> (seconds: TimeInterval, binding: String)? {
        if case .left(let seconds, let binding)? = pace { return (seconds, binding) }
        return nil
    }
    // Steady 30% an hour on the 5-hour limit with 26% left: about 52 minutes.
    let heavy = paced(session: [44, 51.5, 59, 66.5, 74], week: [10, 10.5, 11, 11.5, 12], fable: [9, 9.5, 10, 10.5, 11])
    let heavyLeft = left(ClaudeQuotaSource.fablePace(heavy, now: cacheNow))
    assert(heavyLeft.map { abs($0.seconds - 3120) < 1 && $0.binding == "5h" } == true, String(describing: heavyLeft))
    assert(ClaudeQuotaSource.fablePace(heavy, now: cacheNow)?.menuText == "≈50m left")
    // A late burst is averaged with the quiet hour before it instead of projecting the burst rate.
    let burst = paced(session: [30, 30, 30, 30, 42], week: [10, 10, 10, 10, 11], fable: [10, 10, 10, 10, 11], sessionReset: 5 * 3600)
    let burstLeft = left(ClaudeQuotaSource.fablePace(burst, now: cacheNow))
    let instant = (100 - 42) / (12.0 / 900)
    assert(burstLeft.map { $0.seconds > 2.5 * instant && $0.binding == "5h" } == true, String(describing: burstLeft))
    assert(ClaudeQuotaSource.fablePace(paced(session: [20, 25], week: [5, 6], fable: [5, 6]), now: cacheNow) == .learning, "Fifteen minutes is not yet an average")
    assert(ClaudeQuotaSource.fablePace(paced(session: [20, 20, 20], week: [5, 5, 5], fable: [5, 5, 5]), now: cacheNow) == .idle)
    assert(ClaudeQuotaSource.fablePace(paced(session: [20, 21, 22], week: [5, 5.1, 5.2], fable: [5, 5.1, 5.2]), now: cacheNow) == .resetsFirst)
    assert(ClaudeQuotaSource.fablePace(paced(session: [80, 90, 5, 10], week: [5, 5, 5, 5], fable: [5, 5, 5, 5]), now: cacheNow) == .learning,
           "A new period relearns instead of borrowing the previous period's burn")
    let jittered = paced(session: [44, 51.5, 59, 66.5, 74], week: [10, 10.5, 11, 11.5, 12], fable: [9, 9.5, 10, 10.5, 11], resetJitter: 0.4)
    assert(left(ClaudeQuotaSource.fablePace(jittered, now: cacheNow)) != nil, "Sub-second reset jitter stays one period")
    assert(ClaudeQuotaCache.date("2026-09-15T22:40:00.453396+00:00") == ClaudeQuotaCache.date("2026-09-15T22:40:00.251995+00:00"))
    assert(ClaudeQuotaSource.fablePace(paced(session: [90, 95, 100], week: [5, 5, 5], fable: [5, 5, 5]), now: cacheNow) == .exhausted)
    var noScoped = heavy; noScoped.scoped = []
    assert(ClaudeQuotaSource.fablePace(noScoped, now: cacheNow) == nil, "No Fable budget, no time left")
    var foreign = heavy
    foreign.paceHistory = heavy.paceHistory.map { var copy = $0; copy.accountID = ClaudeQuotaSource.accountID("b"); return copy }
    assert(ClaudeQuotaSource.fablePace(foreign, now: cacheNow) == .learning, "Another account's history never supplies pace")
    assert(Pace.left(9600, binding: "5h").menuText == "≈2h 40m left" && Pace.left(7300, binding: "week").menuText == "≈2h left")
    assert(Pace.left(110_500, binding: "week").menuText == "≈1d 6h left" && Pace.left(200, binding: "5h").menuText == "<5m left")
    assert(Pace.learning.menuText == "learning pace" && Pace.idle.menuText == "no recent use"
           && Pace.resetsFirst.menuText == "resets first" && Pace.exhausted.menuText == "0m left")

    // Beside the figure the projection is smaller and secondary; alone it names Fable; an unknown budget adds no second notice.
    var paceMenu = MenuBarConfiguration(); paceMenu.enabled = [.fable, .fablePace]; paceMenu.tool = .claude
    assert(!MenuBarConfiguration().enabled.contains(.fablePace), "Time left is opt-in")
    let paceTitle = MenuBarPresentation.attributed(paceMenu, meter: meter, monitor: monitor, now: cacheNow, tool: .claude, claudeQuota: heavy)
    assert(paceTitle.string == "Claude  Fable 26% · 5h  ≈50m left", paceTitle.string)
    let paceRange = (paceTitle.string as NSString).range(of: "≈50m left")
    assert((paceTitle.attribute(.font, at: paceRange.location, effectiveRange: nil) as? NSFont)?.pointSize == 11)
    assert((paceTitle.attribute(.foregroundColor, at: paceRange.location, effectiveRange: nil) as? NSColor) == .secondaryLabelColor)
    let unknownBudget = MenuBarPresentation.attributed(paceMenu, meter: meter, monitor: monitor, now: cacheNow, tool: .claude, claudeQuota: noScoped)
    assert(unknownBudget.string == "Claude", unknownBudget.string)
    paceMenu.enabled = [.fablePace]
    assert(MenuBarPresentation.values(paceMenu, meter: meter, monitor: monitor, now: cacheNow, claudeQuota: heavy)[.fablePace] == "Fable ≈50m left")
    assert(MenuBarPresentation.values(paceMenu, meter: meter, monitor: monitor, now: cacheNow)[.fablePace] == "")

    // The monitor keeps recent readings per signed-in account, including through a stale cache.
    let historyRoot = FileManager.default.temporaryDirectory.appendingPathComponent("tokenbar-fable-pace-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: historyRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: historyRoot) }
    let historyCache = historyRoot.appendingPathComponent("claude.json")
    let paceMonitor = ClaudeQuotaMonitor(cacheURL: historyCache, relayURL: historyRoot.appendingPathComponent("relay.json"))
    func settlePace(_ done: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !done() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
    try claudeLimitsCache(at: Date()).write(to: historyCache)
    paceMonitor.refresh()
    settlePace { paceMonitor.quota.paceHistory.count == 3 }
    assert(paceMonitor.quota.paceHistory.count == 3, "Both windows and the Fable row enter the pace history")
    try claudeLimitsCache(session: 40, at: Date()).write(to: historyCache)
    paceMonitor.refresh()
    settlePace { paceMonitor.quota.paceHistory.count == 6 }
    assert(paceMonitor.quota.paceHistory.count == 6)
    try claudeLimitsCache(at: Date(), age: 7200).write(to: historyCache)
    paceMonitor.refresh()
    settlePace { paceMonitor.quota.readings.isEmpty }
    assert(paceMonitor.quota.readings.isEmpty && paceMonitor.quota.paceHistory.count == 6, "A stale cache keeps the same account's pace history")
    try JSONSerialization.data(withJSONObject: ["oauthAccount": ["accountUuid": "b"]]).write(to: historyCache)
    paceMonitor.refresh()
    settlePace { paceMonitor.quota.paceHistory.isEmpty }
    assert(paceMonitor.quota.paceHistory.isEmpty, "Another sign-in drops the previous account's pace history")
    print("PASS: Fable time left averages recent burn per limit, smooths bursts, relearns after resets, ignores jitter and other accounts, and renders small secondary copy")
}
