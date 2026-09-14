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
assert(older.order.suffix(2) == [.dial, .risk] && older.enabled == [.activity, .rate], "Add new option without changing saved selections")
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
assert(LiveTool.visible(codex: soloCodex, claude: joiningClaude) == [.codex])
soloCodex.hasRate = true
assert(LiveTool.visible(codex: soloCodex, claude: joiningClaude) == [.codex])
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
assert(LiveTool.visible(codex: idleCodex, claude: idleClaude, grok: staleGrok) == [.codex])
assert(MenuBarTool.auto.resolve(codex: idleCodex, claude: idleClaude, grok: staleGrok) == .codex)
let unconfirmed = MenuBarPresentation.combined(grokOnlyConfig, codex: idleCodex, claude: idleClaude, grok: staleGrok,
    monitor: monitor, now: now, palette: ToolPalette(), claudeQuota: ToolQuotaState())
assert(unconfirmed.string.hasPrefix("Codex"), "Stale Grok activity must not keep an inactive tool visible")
monitor.currentID = "a"
var autoGrokQuota = MenuBarConfiguration(); autoGrokQuota.enabled = [.rate, .quota]
let grokWithCodexQuota = MenuBarPresentation.combined(autoGrokQuota, codex: idleCodex, claude: idleClaude, grok: openGrok,
    monitor: monitor, now: now, palette: ToolPalette(), claudeQuota: ToolQuotaState())
assert(grokWithCodexQuota.string.hasPrefix("Grok") && grokWithCodexQuota.string.contains("Codex 40% remaining"))
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
print("PASS: Auto keeps Codex remaining beside Grok speed; explicit Grok does not inherit Codex quota")
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
                    // Auto retains the idle Codex status item, without an inactive Grok panel.
                    let expected = label
                    assert(composed.string.components(separatedBy: expected).count - 1 == 1,
                           "One tool label per readout: \(composed.string)")
                    let plain = MenuBarPresentation.title(choice, meter: idleCodex, monitor: monitor, now: date, tool: .codex)
                    assert(plain.components(separatedBy: "Codex").count - 1 == 1, "Plain titles follow the same identity rule")
                }
            }
        }
    }
}
print("PASS: every field subset, compactness and order direction names the selected tool exactly once, including stale quota")

// Live panels have no idle fallback and no quota-only provider sections.
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
