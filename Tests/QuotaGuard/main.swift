import Foundation
import Observation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    checks += 1
    if !condition() { fputs("FAIL: \(label)\n", stderr); exit(1) }
}
let base = Date(timeIntervalSince1970: 2_000_000_000)
func reading(_ offset: Double = 0, used: Double = 92, account: String = "synthetic-a", window: String = "primary", reset: Double = 7200) -> QuotaReading {
    QuotaReading(accountID: account, bucket: "general", name: "Synthetic allowance", window: window, minutes: window == "primary" ? 300 : 10080, used: used, reset: base.addingTimeInterval(reset), date: base.addingTimeInterval(offset))
}
func input(_ r: QuotaReading, samples: [QuotaReading] = [], tool: LiveTool = .codex) -> QuotaGuardInput {
    QuotaGuardInput(tool: tool, accountID: r.accountID, readings: [r], samples: samples, authenticated: true)
}
func decision(_ i: QuotaGuardInput, now: Date = base) -> QuotaGuardDecision {
    QuotaGuardEvaluator.evaluate(i, now: now, policy: QuotaGuardPolicy())[0]
}
let low = decision(input(reading()))
check(low.risk == .low && low.evidence == .insufficient && low.remaining == 8, "fresh low remains actionable while learning")
check(decision(input(reading(used: 100))).risk == .observedExhaustion, "provider 100 percent is observed exhaustion")
for value in [Double.nan, .infinity, -1, 101] {
    let d = decision(input(reading(used: value)))
    check(d.evidence == .invalid && d.remaining == nil && d.risk == .none, "invalid reading never supplies capacity")
}
check(decision(input(reading(1))).reason == .future, "future source rejected")
check(decision(input(reading(reset: 0))).reason == .expiredReset, "expired reset rejected")
check(decision(input(reading(-120))).evidence == .stale, "freshness boundary exact")
var mismatched = input(reading()); mismatched.accountID = "synthetic-b"
check(decision(mismatched).reason == .identityMismatch, "account mismatch")
var restored = input(reading()); restored.authenticated = false
check(decision(restored).reason == .restored, "restored quota requires authentication")
var failed = input(reading()); failed.failed = true
check(decision(failed).reason == .providerError, "failure cannot reuse fresh old reading")
var relay = input(reading()); relay.relay = true
check(decision(relay).reason == .unsupportedSource, "relay cannot authenticate")
var claude = input(reading(-121), tool: .claude); claude.horizon = 1800
check(decision(claude).evidence == .stale, "guard tightens Claude without altering display")
var strict = input(reading(-61)); strict.horizon = 60
check(decision(strict).evidence == .stale, "shorter provider horizon preserved")
let burn = [reading(-120, used: 70), reading(-60, used: 75), reading(used: 80)]
let forecast = decision(input(burn[2], samples: burn))
check(forecast.risk == .projectedExhaustion && forecast.forecast == base.addingTimeInterval(240), "canonical projection")
check(forecast.forecast == Runway.estimate(burn[2], samples: burn, now: base).exhaustion, "one Runway formula")
let flat = [reading(-120, used: 50), reading(-60, used: 50), reading(used: 50)]
check(decision(input(flat[2], samples: flat)).reason == .flat, "flat burn no fabricated forecast")
let beforeReset = burn.map { r -> QuotaReading in var r = r; r.reset = base.addingTimeInterval(200); return r }
check(decision(input(beforeReset[2], samples: beforeReset)).forecast == nil, "reset before forecast excludes warning")
check(decision(input(burn[2], samples: [reading(-300, used: 50), burn[2]])).reason == .gap, "gap not bridged")
check(decision(input(reading(used: 50), samples: [reading(-120, used: 80), reading(-60, used: 90)])).forecast == nil, "quota decrease clears slope")
check(decision(input(burn[2], samples: burn + [reading(-30, used: .nan)])).forecast == nil, "NaN history cannot disappear in filtering")
check(decision(input(burn[2], samples: burn + [reading(1, used: 90)])).forecast == nil, "future history cannot disappear")
check(decision(input(burn[2], samples: [burn[0], reading(-60, used: 75), reading(-60, used: 76)])).reason == .duplicate, "conflicting timestamp invalidates segment")
check(decision(input(burn[2], samples: [burn[1], burn[0]])).forecast == nil, "out of order cannot reconstruct slope")
check(decision(input(reading(-119, used: 99), samples: [reading(-239, used: 10), reading(-179, used: 50)] )).risk != .observedExhaustion, "elapsed projection never observed exhaustion")
check(QuotaGuardEvaluator.prioritized([low, forecast, decision(input(reading(used: 100)))])[0].risk == .observedExhaustion, "observed exhaustion wins priority")
print("PASS: evaluator evidence, boundaries, canonical forecast, discontinuities and priority")

final class FakeNotifications: QuotaNotificationAdapter {
    var action: ((String, Bool) -> Void)?
    var requests: [QuotaNotification] = []
    var removed: [String] = []
    var permissionRequests = 0
    var status: QuotaNotificationPermission = .authorized
    var held = false
    var succeeds = true
    var callbacks: [(Bool) -> Void] = []
    var observed: Set<String> = []
    var queued: Set<String> = []
    func permission(request: Bool, completion: @escaping (QuotaNotificationPermission) -> Void) { if request { permissionRequests += 1 }; completion(status) }
    func submit(_ n: QuotaNotification, completion: @escaping (Bool) -> Void) { requests.append(n); if held { callbacks.append(completion) } else { completion(succeeds) } }
    func pending(_ completion: @escaping (Set<String>) -> Void) { completion(queued) }
    func delivered(_ completion: @escaping (Set<String>) -> Void) { completion(observed) }
    func remove(_ ids: [String]) { removed += ids; observed.subtract(ids); queued.subtract(ids) }
}
final class Fixture {
    var now = base
    let url: URL
    let adapter = FakeNotifications()
    var guardModel: QuotaGuardCoordinator!
    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("quota-guard-tests-" + UUID().uuidString).appendingPathComponent("state.json")
        guardModel = QuotaGuardCoordinator(url: url, adapter: adapter, clock: { [unowned self] in self.now })
        guardModel.reveal = {}
    }
    deinit { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    func enable() { var settings = guardModel.settings; settings.notifications = true; guardModel.configure(settings, userEnabled: true) }
    func update(_ r: QuotaReading, samples: [QuotaReading] = []) { now = r.date; guardModel.update([input(r, samples: samples)]) }
}
do {
    let f = Fixture(); check(f.adapter.permissionRequests == 0 && !f.guardModel.settings.sound, "no launch permission and default silent")
    f.update(reading()); check(f.adapter.requests.isEmpty, "opt-in off")
    f.enable(); check(f.adapter.permissionRequests == 1 && f.adapter.requests.isEmpty, "enable not a fresh source event")
    f.update(reading(30)); check(f.adapter.requests.count == 1, "next fresh low alerts")
    let request = f.adapter.requests[0]
    check(!request.sound && !request.body.contains("synthetic-a") && !request.id.contains("synthetic-a") && request.id.count < 100, "opaque bounded notification without account data")
    check(f.guardModel.submissionState.contains("delivery not confirmed"), "submitted differs from delivered")
    f.guardModel.tick(); f.update(reading(30)); f.update(reading(60))
    check(f.adapter.requests.count == 1, "ticks duplicates and steady low do not repeat")
    f.update(reading(90, used: 96)); check(f.adapter.requests.count == 2, "more severe threshold escalates")
    f.update(reading(120, used: 100)); check(f.adapter.requests.count == 3, "observed exhaustion escalates")
    f.update(reading(150, account: "synthetic-b")); f.update(reading(180))
    check(f.adapter.requests.count == 4, "returning account retains suppression")
    f.guardModel = QuotaGuardCoordinator(url: f.url, adapter: f.adapter, clock: { f.now }); f.guardModel.reveal = {}
    f.update(reading(210)); check(f.adapter.requests.count == 4, "restart suppression persisted")
    f.adapter.observed = [request.id]; f.guardModel.reconcile()
    let attributes = try FileManager.default.attributesOfItem(atPath: f.url.path)
    check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "private suppression file")
}
do {
    let f = Fixture(); f.enable(); f.update(burn[2], samples: burn)
    check(f.adapter.requests.isEmpty, "forecast first observation does not alert")
    f.guardModel.tick(); f.update(burn[2], samples: burn)
    check(f.adapter.requests.isEmpty, "ticks and unchanged cache do not confirm")
    f.update(reading(30, used: 82.5), samples: burn)
    check(f.adapter.requests.count == 1, "second distinct fresh forecast alerts")
    let old = f.guardModel.decisions[0]; f.guardModel.view(old)
    f.now = base.addingTimeInterval(151); f.guardModel.tick()
    check(f.guardModel.selectedEvidence?.evidence == .stale && f.guardModel.selectedEvidence?.forecast == nil, "selected detail ages and removes forecast")
    f.update(reading(180, used: 84)); check(f.adapter.requests.count == 1, "after gap forecast relearns")
}
do {
    let f = Fixture(); f.enable(); f.update(reading(reset: 600)); let old = f.guardModel.decisions[0]
    f.guardModel.snooze(old)
    f.now = base.addingTimeInterval(30)
    f.guardModel.update([input(reading(30, used: 99, reset: 630)), input(reading(30, used: 96, window: "weekly"))])
    check(f.adapter.requests.count == 2, "snooze blocks escalation and jitter but independent weekly alerts")
    f.guardModel.view(old); check(f.guardModel.selectedIsCurrent, "reset jitter retains selected period")
    f.update(reading(60, used: 99, reset: 670))
    check(f.adapter.requests.count == 2, "jitter cannot drift via a chain")
    f.update(reading(601, used: 92, reset: 4200))
    check(f.adapter.requests.count == 3 && !f.guardModel.isSnoozed(f.guardModel.decisions[0]), "new period not snoozed")
    let currentID = f.adapter.requests.last!.id; let removedCount = f.adapter.removed.count
    f.guardModel.snooze(old)
    check(!f.adapter.removed.dropFirst(removedCount).contains(currentID), "old snapshot snooze never removes new period")
}
do {
    let f = Fixture(); f.enable(); f.update(reading()); f.guardModel.snooze(f.guardModel.decisions[0])
    f.update(reading(1799, used: 99)); check(f.adapter.requests.count == 1, "full 30 minute snooze")
    f.update(reading(1800, used: 99)); check(f.adapter.requests.count == 2, "fresh escalation after snooze expires")
}
do {
    let f = Fixture(); f.enable(); f.adapter.succeeds = false
    f.update(reading()); f.update(reading(30)); check(f.adapter.requests.count == 1, "retry delay")
    f.update(reading(60)); f.update(reading(120)); check(f.adapter.requests.count == 2, "bounded retry on fresh evidence")
    check(f.adapter.requests[0].id == f.adapter.requests[1].id, "retry idempotent identifier")
}
do {
    let f = Fixture(); f.enable(); f.adapter.held = true; f.update(reading())
    let id = f.adapter.requests[0].id
    f.now = base.addingTimeInterval(121); f.adapter.callbacks[0](true)
    check(f.adapter.removed.contains(id), "late callback checks clock even before UI tick")
}
do {
    let f = Fixture(); f.enable(); f.adapter.held = true; f.update(reading())
    let id = f.adapter.requests[0].id; f.guardModel.snooze(f.guardModel.decisions[0]); f.adapter.callbacks[0](true)
    check(f.adapter.removed.contains(id), "pending submit cancelled by snooze")
    f.update(reading(30, account: "synthetic-b")); f.adapter.callbacks[0](true)
    check(f.adapter.requests.count == 2, "callback never resubmits after account switch")
}
do {
    let f = Fixture(); f.enable(); f.update(reading()); let id = f.adapter.requests[0].id
    var opened = 0
    f.guardModel = QuotaGuardCoordinator(url: f.url, adapter: f.adapter, clock: { f.now })
    f.adapter.action?(id, false)
    f.guardModel.update([input(reading(30, account: "synthetic-b"))])
    check(f.guardModel.selected == nil, "cold action waits for navigation")
    f.guardModel.reveal = { opened += 1 }
    check(opened == 1 && f.guardModel.selected?.accountID == "synthetic-a" && !f.guardModel.selectedIsCurrent, "cold action retains exact old account")
}
do {
    let f = Fixture(); f.enable(); f.update(reading())
    f.update(reading(30, used: 86), samples: [reading(-90, used: 86), reading(-30, used: 86)])
    f.update(reading(60)); check(f.adapter.requests.count == 1, "one recovery observation insufficient")
    f.update(reading(90, used: 80), samples: [reading(-30, used: 80), reading(30, used: 80)])
    f.update(reading(120, used: 80), samples: [reading(0, used: 80), reading(60, used: 80)])
    f.update(reading(150)); check(f.adapter.requests.count == 2, "two distinct recovered observations rearm")
}
do {
    let f = Fixture(); f.adapter.status = .denied; f.enable(); f.update(reading())
    check(f.guardModel.permission == .denied && f.adapter.requests.isEmpty && f.guardModel.decisions[0].risk == .low, "denial keeps in-app warning")
    try Data("corrupt".utf8).write(to: f.url)
    f.guardModel = QuotaGuardCoordinator(url: f.url, adapter: f.adapter, clock: { f.now })
    f.enable(); f.update(reading(30))
    check(f.guardModel.persistenceError != nil && f.adapter.requests.isEmpty && (try? String(contentsOf: f.url, encoding: .utf8)) == "corrupt", "corrupt state preserves bytes and cannot replay alerts")
}
print("PASS: opt-in, forecast confirmation, hysteresis, escalation, snooze isolation, restart, retries, callbacks and cold routes")
var config = MenuBarConfiguration(); config.order = [.quota, .rate, .dial, .icon, .activity, .zero]; config.enabled = [.quota, .rate]; config.tool = .claude; config.unit = "h"; config.normalize()
check(Array(config.order.prefix(6)) == [.quota, .rate, .dial, .icon, .activity, .zero] && config.order.suffix(3) == [.risk, .fable, .fablePace]
      && config.enabled == [.quota, .rate] && config.tool == .claude && config.unit == "h", "risk migration preserves selections/order")
check(!MenuBarConfiguration().enabled.contains(.risk), "risk field not autoenabled")
check(QuotaGuardPolicy().lowPercent == 10 && QuotaGuardPolicy().leadMinutes == 30 && QuotaGuardPolicy.escalationPercent == 5 && QuotaGuardPolicy.escalationLead == 600 && QuotaGuardPolicy.snooze == 1800, "product defaults pinned")
let higherUsed = decision(input(reading(used: 96)))
check(QuotaGuardEvaluator.prioritized([higherUsed, forecast])[0].id == forecast.id && QuotaGuardEvaluator.prioritized([higherUsed, forecast])[0].forecast != nil, "earliest forecast wins over higher used without forecast")
var missingWindow = reading(); missingWindow.window = ""
check(decision(input(missingWindow)).evidence == .invalid, "empty window cannot become unnamed allowance")
let empty = QuotaGuardInput(tool: .grok, readings: [], samples: [])
check(decision(empty).evidence == .unavailable && decision(empty).remaining == nil, "missing quota not zero")
do {
    let f = Fixture(); f.enable()
    var general = reading(); general.name = "forged private-label secret@example.invalid"; general.accountID = "private-account@example.invalid"
    var bucket = general; bucket.bucket = "model-specific"
    f.guardModel.update([input(general), input(bucket), input(general, tool: .claude), input(general, tool: .grok)])
    check(f.adapter.requests.count == 4 && Set(f.adapter.requests.map(\.id)).count == 4, "three tools and model buckets have independent identities")
    check(f.adapter.requests.allSatisfy { !$0.body.contains("private") && !$0.body.contains("@") && !$0.title.contains("secret") }, "private forged label never enters notification payload")
    let target = f.guardModel.decisions.first { $0.tool == .grok }!
    let request = f.adapter.requests.first { $0.title.hasPrefix("Grok") }!
    f.adapter.action?(request.id, true)
    check(f.guardModel.isSnoozed(target) && f.guardModel.decisions.filter { $0.id != target.id }.allSatisfy { !f.guardModel.isSnoozed($0) }, "adapter Snooze true targets only exact allowance")
    f.adapter.observed = [f.adapter.requests[0].id]; f.guardModel.reconcile()
    check(f.guardModel.submissionState == "Delivery observed by macOS", "actual adapter delivery receipt distinct from submission")
}
do {
    let f = Fixture(); f.enable()
    for index in 0..<360 { f.update(reading(Double(index) * 30, reset: 20000)) }
    check(f.adapter.requests.count == 1, "three-hour sustained source stream sends one warning")
    for index in 0..<300 { f.update(reading(10800 + Double(index), account: "synthetic-capacity-\(index)", reset: 20000)) }
    let stored = try JSONDecoder().decode(QuotaGuardDisk.self, from: Data(contentsOf: f.url))
    check(stored.episodes.count == 256 && f.adapter.requests.count == 256 && f.guardModel.decisions[0].risk == .low, "bounded capacity retains suppression and in-app assessment")
}
do {
    let f = Fixture(); f.enable(); f.update(reading()); let firstID = f.adapter.requests[0].id
    f.adapter.observed = [firstID]; f.update(reading(30, used: 96))
    check(f.adapter.removed.contains(firstID) && !f.adapter.observed.contains(firstID), "escalation retires previous OS notification")
    let latestID = f.adapter.requests.last!.id
    f.adapter.observed = [latestID, "quota-orphan-delivered", "other-feature-delivered"]
    f.adapter.queued = ["quota-orphan-pending", "other-feature-pending"]
    f.guardModel = QuotaGuardCoordinator(url: f.url, adapter: f.adapter, clock: { f.now })
    check(f.adapter.removed.contains("quota-orphan-delivered") && f.adapter.removed.contains("quota-orphan-pending") && !f.adapter.removed.contains(latestID), "restart cleans orphan pending and delivered own requests")
    check(f.adapter.observed.contains("other-feature-delivered") && f.adapter.queued.contains("other-feature-pending"), "other notification namespaces preserved")
    f.now = base.addingTimeInterval(36 * 86400); f.guardModel.tick()
    check(f.adapter.removed.contains(latestID), "expired retained episode retires OS request")
    let stored = try JSONDecoder().decode(QuotaGuardDisk.self, from: Data(contentsOf: f.url))
    check(stored.episodes.isEmpty, "pruning is durable even on aging tick")
}
do {
    let f = Fixture(); f.enable(); f.update(reading())
    let target = f.guardModel.decisions[0]
    let changed = DispatchSemaphore(value: 0)
    withObservationTracking { _ = f.guardModel.isSnoozed(target) } onChange: { changed.signal() }
    f.guardModel.snooze(target)
    check(changed.wait(timeout: .now()) == .success && f.guardModel.isSnoozed(target), "snooze invalidates rendered controls without a clock or source update")
}
print("PASS: \(checks) Quota Guard checks; all data, clock, persistence and notification adapters synthetic")
