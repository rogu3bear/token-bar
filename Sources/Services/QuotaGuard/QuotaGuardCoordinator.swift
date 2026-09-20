import Foundation
import Observation

struct QuotaGuardSettings: Codable, Equatable {
    var policy = QuotaGuardPolicy()
    var notifications = false
    var sound = false
}
enum QuotaNotificationPermission: String { case unavailable, notDetermined, denied, authorized }
struct QuotaNotification {
    var id: String
    var title: String
    var body: String
    var sound: Bool
}
protocol QuotaNotificationAdapter: AnyObject {
    var action: ((String, Bool) -> Void)? { get set }
    func permission(request: Bool, completion: @escaping (QuotaNotificationPermission) -> Void)
    func submit(_ notification: QuotaNotification, completion: @escaping (Bool) -> Void)
    func pending(_ completion: @escaping (Set<String>) -> Void)
    func delivered(_ completion: @escaping (Set<String>) -> Void)
    func remove(_ ids: [String])
}
struct QuotaEpisode: Codable {
    var period = UUID().uuidString
    var reset: Date
    var lastObservation: Date
    var forecastCount = 0
    var recoveryCount = 0
    var level = 0
    var requestID: String?
    var submitted: Date?
    var delivered: Date?
    var failed = false
    var target: QuotaGuardDecision?
    var attempts = 0
}
struct QuotaGuardDisk: Codable {
    var version = 1
    var settings = QuotaGuardSettings()
    var episodes: [String: QuotaEpisode] = [:]
    var snoozes: [String: Date] = [:]
}
/// One process owner. Persistent state contains suppression, not a quota-history copy.
@Observable final class QuotaGuardCoordinator {
    private(set) var settings = QuotaGuardSettings()
    private(set) var decisions: [QuotaGuardDecision] = []
    private(set) var snoozedUntil: [String: Date] = [:]
    private(set) var permission: QuotaNotificationPermission = .unavailable
    private(set) var persistenceError: String?
    private(set) var submissionState = "Notifications off"
    var selected: QuotaGuardDecision?
    @ObservationIgnored var reveal: (() -> Void)? { didSet {
        guard reveal != nil, hasInputs else { return }
        let queued = queuedActions; queuedActions = []
        for (id, snooze) in queued { handleAction(id: id, snooze: snooze) }
    } }
    @ObservationIgnored private let url: URL
    @ObservationIgnored private let adapter: QuotaNotificationAdapter?
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var disk = QuotaGuardDisk()
    @ObservationIgnored private var inputs: [QuotaGuardInput] = []
    @ObservationIgnored private var ready = false
    @ObservationIgnored private var queuedActions: [(String, Bool)] = []
    @ObservationIgnored private var hasInputs = false
    @ObservationIgnored private var lastPrune = Date.distantPast
    init(url: URL, adapter: QuotaNotificationAdapter? = nil, clock: @escaping () -> Date = Date.init) {
        self.url = url; self.adapter = adapter; self.clock = clock
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                disk = try JSONDecoder().decode(QuotaGuardDisk.self, from: Data(contentsOf: url))
                guard disk.version == 1, disk.settings.policy.valid, disk.episodes.count <= QuotaGuardPolicy.capacity,
                      disk.snoozes.count <= QuotaGuardPolicy.capacity, disk.episodes.values.allSatisfy({ $0.reset.timeIntervalSince1970.isFinite && $0.lastObservation.timeIntervalSince1970.isFinite && (0...3).contains($0.level) && (0...QuotaGuardPolicy.maximumAttempts).contains($0.attempts) }) else { throw CocoaError(.fileReadCorruptFile) }
                settings = disk.settings; snoozedUntil = disk.snoozes
            } catch { persistenceError = "Quota Guard state could not be read. Notifications are paused; saved state is preserved." }
        }
        adapter?.action = { [weak self] id, snooze in self?.handleAction(id: id, snooze: snooze) }
        adapter?.permission(request: false) { [weak self] in self?.permission = $0 }
        reconcile()
    }
    private func save() -> Bool {
        guard persistenceError == nil else { return false }
        do { try PrivateCache.write(disk, to: url); return true }
        catch { persistenceError = "Quota Guard state could not be saved. Notifications are paused."; return false }
    }
    func configure(_ value: QuotaGuardSettings, userEnabled: Bool = false) {
        guard value.policy.valid else { return }
        let wasEnabled = settings.notifications
        settings = value; disk.settings = value
        guard save() else { return }
        if !value.notifications {
            adapter?.remove(disk.episodes.values.compactMap(\.requestID)); submissionState = "Notifications off"
        } else if userEnabled && !wasEnabled {
            adapter?.permission(request: true) { [weak self] permission in
                self?.permission = permission // A permission callback never manufactures an observation.
            }
        }
        tick()
    }
    func reconcile() {
        guard let adapter else { ready = true; return }
        adapter.pending { [weak self] pending in
            adapter.delivered { [weak self] ids in
                guard let self else { return }
                self.prune(now: self.clock())
                let known = self.persistenceError == nil && self.settings.notifications ? Set(self.disk.episodes.values.compactMap(\.requestID)) : []
                let orphans = pending.union(ids).filter { $0.hasPrefix(QuotaGuardAction.requestPrefix) && !known.contains($0) }
                if !orphans.isEmpty { adapter.remove(Array(orphans)) }
                var changed = false
                for key in self.disk.episodes.keys {
                    if let id = self.disk.episodes[key]?.requestID, ids.contains(id), known.contains(id), self.disk.episodes[key]?.delivered == nil {
                        self.disk.episodes[key]?.delivered = self.clock(); changed = true
                        self.submissionState = "Delivery observed by macOS"
                    }
                }
                if changed { _ = self.save() }
                self.ready = true
            }
        }
    }
    private func prune(now: Date) {
        guard persistenceError == nil, now.timeIntervalSince(lastPrune) > 3600 else { return }
        let expired = disk.episodes.filter { now.timeIntervalSince($0.value.lastObservation) >= QuotaGuardPolicy.retention && $0.value.reset <= now }
        let snoozes = disk.snoozes.filter { $0.value > now }
        lastPrune = now
        guard !expired.isEmpty || snoozes.count != disk.snoozes.count else { return }
        for key in expired.keys { disk.episodes.removeValue(forKey: key) }
        disk.snoozes = snoozes
        if save() {
            snoozedUntil = disk.snoozes
            adapter?.remove(expired.values.compactMap(\.requestID))
        }
    }
    func update(_ inputs: [QuotaGuardInput]) {
        self.inputs = inputs; hasInputs = true
        evaluate(allowNotifications: true)
        let queued = queuedActions; queuedActions = []
        for (id, snooze) in queued { handleAction(id: id, snooze: snooze) }
    }
    func tick() { evaluate(allowNotifications: false) }
    private func evaluate(allowNotifications: Bool) {
        let now = clock()
        decisions = QuotaGuardEvaluator.prioritized(inputs.flatMap { QuotaGuardEvaluator.evaluate($0, now: now, policy: settings.policy) })
        prune(now: now)
        guard allowNotifications, ready, persistenceError == nil else { return }
        for decision in decisions {
            guard let reading = decision.reading, let reset = reading.reset, decision.remaining != nil,
                  decision.evidence == .current || decision.evidence == .insufficient else { continue }
            var retired: [String] = []
            var episode = disk.episodes[decision.id]
            if let old = episode {
                guard reading.date > old.lastObservation else { continue }
                // Compare with a stable anchor, not the previous jittered reset.
                if abs(reset.timeIntervalSince(old.reset)) > QuotaGuardPolicy.resetJitter {
                    guard reading.date >= old.reset, reset > old.reset else { continue }
                    if let id = old.requestID { retired.append(id) }
                    episode = nil
                }
            }
            guard episode != nil || disk.episodes.count < QuotaGuardPolicy.capacity else { continue }
            var next = episode ?? QuotaEpisode(reset: reset, lastObservation: .distantPast)
            let gap = reading.date.timeIntervalSince(next.lastObservation)
            if gap > QuotaGuardPolicy.maximumGap { next.forecastCount = 0; next.recoveryCount = 0 }
            next.lastObservation = reading.date
            next.forecastCount = decision.risk == .projectedExhaustion ? min(QuotaGuardPolicy.confirmations, next.forecastCount + 1) : 0
            let recovered = decision.remaining! > settings.policy.lowPercent + QuotaGuardPolicy.recoveryMargin &&
                (decision.forecast == nil || decision.forecast!.timeIntervalSince(now) > settings.policy.leadMinutes * 60 + QuotaGuardPolicy.recoveryLead) &&
                decision.evidence == .current
            next.recoveryCount = recovered ? min(QuotaGuardPolicy.confirmations, next.recoveryCount + 1) : 0
            if next.recoveryCount >= QuotaGuardPolicy.confirmations {
                if let id = next.requestID { retired.append(id) }
                next.level = 0; next.requestID = nil; next.attempts = 0; next.failed = false
                next.submitted = nil; next.delivered = nil
                next.period = UUID().uuidString; next.recoveryCount = 0
            }
            let confirmed = decision.risk != .projectedExhaustion || next.forecastCount >= QuotaGuardPolicy.confirmations
            let retry = next.failed && next.attempts < QuotaGuardPolicy.maximumAttempts && next.submitted.map { now.timeIntervalSince($0) >= QuotaGuardPolicy.retryDelay } == true
            let eligible = confirmed && decision.level > 0 && (decision.level > next.level || retry) &&
                settings.notifications && permission == .authorized && !isSnoozed(decision, now: now)
            if eligible {
                let previousID = next.requestID
                if decision.level > next.level { next.attempts = 0 }
                next.level = decision.level; next.attempts += 1; next.failed = false
                next.submitted = now; next.delivered = nil; next.target = decision
                next.requestID = QuotaGuardAction.requestPrefix + decision.id.prefix(24) + "-" + next.period + "-" + String(next.level)
                if let previousID, previousID != next.requestID { retired.append(previousID) }
            }
            disk.episodes[decision.id] = next
            guard save() else { continue }
            if !retired.isEmpty { adapter?.remove(retired) }
            guard eligible, let requestID = next.requestID else { continue }
            // Submit only from this fresh source event. Async completions never submit another request.
            submissionState = "Notification evaluated; submission pending"
            adapter?.submit(QuotaNotification(id: requestID, title: decision.tool.label + " allowance warning",
                body: decision.windowLabel + " allowance " + decision.id.prefix(6) + ": " + CompactLiveCopy.percent(decision.remaining!) + " remaining. " + decision.riskLabel + ". Open Token Bar for the exact allowance and evidence.", sound: settings.sound)) { [weak self] success in
                guard let self else { return }
                guard self.disk.episodes[decision.id]?.requestID == requestID else { self.adapter?.remove([requestID]); return }
                self.disk.episodes[decision.id]?.failed = !success
                self.submissionState = success ? "Submitted to macOS; delivery not confirmed" : "Submission failed; at most one retry on fresh evidence"
                _ = self.save()
                // A switch/snooze/off action while submission was pending must cancel its result.
                let current = self.inputs.flatMap { QuotaGuardEvaluator.evaluate($0, now: self.clock(), policy: self.settings.policy) }
                guard self.settings.notifications, current.contains(where: { $0.id == decision.id && $0.risk != .none && self.samePeriod($0, reset: reset) }),
                      !self.isSnoozed(decision, now: self.clock()) else { self.adapter?.remove([requestID]); return }
                if success { self.reconcile() }
            }
        }
    }
    private func samePeriod(_ decision: QuotaGuardDecision, reset: Date) -> Bool {
        decision.reading.flatMap { reading in reading.reset.map { abs($0.timeIntervalSince(reset)) <= QuotaGuardPolicy.resetJitter } } == true
    }
    private func accountKey(_ decision: QuotaGuardDecision) -> String {
        let anchor = disk.episodes[decision.id].flatMap { samePeriod(decision, reset: $0.reset) ? $0.reset : nil } ?? decision.reading?.reset ?? .distantPast
        return decision.id + ":" + String(anchor.timeIntervalSince1970)
    }
    func isSnoozed(_ decision: QuotaGuardDecision, now: Date? = nil) -> Bool { (snoozedUntil[accountKey(decision)] ?? .distantPast) > (now ?? clock()) }
    func snooze(_ decision: QuotaGuardDecision) {
        guard !decision.accountID.isEmpty, disk.snoozes.count < QuotaGuardPolicy.capacity || disk.snoozes[accountKey(decision)] != nil else { return }
        disk.snoozes[accountKey(decision)] = clock().addingTimeInterval(QuotaGuardPolicy.snooze)
        if let episode = disk.episodes[decision.id], samePeriod(decision, reset: episode.reset) {
            adapter?.remove([episode.requestID].compactMap { $0 })
        }
        if save() { snoozedUntil = disk.snoozes }
        tick()
    }
    func menuText(selection: MenuBarTool?) -> String? {
        let warning = decisions.first { $0.risk != .none && (selection == nil || selection == .auto || selection?.rawValue == $0.tool.rawValue) }
        return warning.map { $0.tool.label + " " + $0.windowLabel + ($0.remaining.map { " " + CompactLiveCopy.percent($0) } ?? "") + " · " + $0.riskLabel }
    }
    func view(_ decision: QuotaGuardDecision) { selected = decision; reveal?() }
    var selectedEvidence: QuotaGuardDecision? {
        guard let selected, let reset = selected.reading?.reset else { return nil }
        let anchor = disk.episodes[selected.id].flatMap { samePeriod(selected, reset: $0.reset) ? $0.reset : nil } ?? reset
        return decisions.first { $0.id == selected.id && samePeriod($0, reset: anchor) }
    }
    var selectedIsCurrent: Bool { selectedEvidence?.remaining != nil }
    func handleAction(id: String, snooze: Bool) {
        guard hasInputs, reveal != nil else {
            if queuedActions.count < 16 { queuedActions.append((id, snooze)) }
            return
        }
        guard let episode = disk.episodes.values.first(where: { $0.requestID == id }), let target = episode.target else {
            selected = nil
            submissionState = "That allowance is no longer current. Open Quota Guard to inspect current evidence."
            reveal?(); return
        }
        if snooze { self.snooze(target) } else { view(target) }
    }
}
