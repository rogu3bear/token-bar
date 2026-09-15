import Foundation
import Darwin
import CryptoKit

struct Tokens: Codable, Equatable {
    var input: Int = 0
    var cached: Int = 0
    var output: Int = 0
    var reasoning: Int = 0
    var cacheWrite: Int?
    var total: Int { input + output }
    init(_ json: [String: Any] = [:]) {
        input = json["input_tokens"] as? Int ?? 0
        cached = json["cached_input_tokens"] as? Int ?? 0
        output = json["output_tokens"] as? Int ?? 0
        reasoning = json["reasoning_output_tokens"] as? Int ?? 0
        cacheWrite = json["cache_write_input_tokens"] as? Int
    }
    func delta(from old: Tokens) -> Tokens {
        var t = Tokens()
        t.input = max(0, input - old.input); t.cached = max(0, cached - old.cached)
        t.output = max(0, output - old.output); t.reasoning = max(0, reasoning - old.reasoning)
        if let value = cacheWrite, let previous = old.cacheWrite { t.cacheWrite = max(0, value - previous) }
        return t
    }
    static func + (a: Tokens, b: Tokens) -> Tokens {
        var t = Tokens()
        t.input = a.input + b.input; t.cached = a.cached + b.cached
        t.output = a.output + b.output; t.reasoning = a.reasoning + b.reasoning
        if let left = a.cacheWrite, let right = b.cacheWrite { t.cacheWrite = left + right }
        return t
    }
}
struct Account: Codable, Equatable {
    var id: String
    var label: String
    var plan: String?
    var planIssuedAt: Date?
    var subscriptionStart: Date?
    var subscriptionUntil: Date?
    var planCheckedAt: Date?
    static func read(home: URL) -> Account? {
        guard let data = try? Data(contentsOf: home.appendingPathComponent("auth.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let tokens = root["tokens"] as? [String: Any], let id = tokens["account_id"] as? String else { return nil }
        var label = "Account …" + id.suffix(8)
        var authClaims: [String: Any] = [:]
        var issued: Date?
        if let jwt = tokens["id_token"] as? String {
            let parts = jwt.split(separator: ".")
            if parts.count > 1 {
                var segment = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                segment += String(repeating: "=", count: (4 - segment.count % 4) % 4)
                if let bytes = Data(base64Encoded: segment), let claims = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                   let email = claims["email"] as? String {
                    label = email + " · …" + id.suffix(6)
                    if let auth = claims["https://api.openai.com/auth"] as? [String: Any], auth["chatgpt_account_id"] as? String == id {
                        authClaims = auth
                        issued = (claims["iat"] as? Double).map { Date(timeIntervalSince1970: $0) }
                    }
                }
            }
        }
        func claimDate(_ key: String) -> Date? {
            if let number = authClaims[key] as? Double { return Date(timeIntervalSince1970: number) }
            if let string = authClaims[key] as? String {
                let format = ISO8601DateFormatter()
                if let date = format.date(from: string) { return date }
                format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return format.date(from: string)
            }
            return nil
        }
        return Account(id: id, label: label, plan: authClaims["chatgpt_plan_type"] as? String, planIssuedAt: issued,
            subscriptionStart: claimDate("chatgpt_subscription_active_start"), subscriptionUntil: claimDate("chatgpt_subscription_active_until"),
            planCheckedAt: claimDate("chatgpt_subscription_last_checked"))
    }
}
struct Entry: Codable, Equatable {
    var date: Date
    var session: String
    var model: String
    var tokens: Tokens
    var account: Account?
    var sampleCount: Int?
    var bucket: String?
    var lastObserved: Date?
    var provider: String?
    /// The client program that ran the turn. Separate from `provider`.
    var harness: String?
    /// Working directory observed for the turn. Evidence, not a display label.
    var projectPath: String?
    /// The model's context window as the harness reported it for this turn.
    /// Absent when the harness did not report one; never assumed from the model name.
    var contextWindow: Int?
    var effort: String?
    var contextBand: String?
    var costMetadataVersion: Int?
    var tokenFields: [String]?
    var recordID: String?
    var turnID: String?
    var requestedService: String?
    var observedService: String?
    var serviceEvidence: String?
    var requestInputTokens: Int?
    var pricingDay: String?
    var firstObserved: Date?
    /// Provider-persisted cost ticks (Grok: 10^10 per USD). Never an OpenAI rate-card estimate.
    var costUsdTicks: Int?
    var eventCount: Int { sampleCount ?? 1 }
}
struct Cursor: Codable, Equatable {
    var offset: UInt64 = 0
    var model = "Unknown model"
    var previous: Tokens?
    var turnID: String?
    var provider: String?
    var harness: String?
    var projectPath: String?
    var effort: String?
    var requestedService: String?
    var previousFields: [String]?
    /// Last admitted Grok session `costUsdTicks`. Codex cursors leave this unset.
    var previousTicks: Int?
    /// Optional for backward-compatible migration of legacy byte cursors.
    var continuity: CodexContinuity?
    var sourceSession: String?
    var lastFingerprint: String?
    var admittedBoundary: CodexCounterBoundary?
    var lastObservation: CodexCounterBoundary?
    var reconciliation: CodexReconciliation?
    var continuityGap: String?
    var aliasWitness: String?
}
struct Quota: Codable {
    var name: String
    var used: Double
    var minutes: Int
    var reset: Date?
    var observed: Date
}
struct Ledger: Codable {
    /// Identifies the exact full-history baseline for a metadata checkpoint.
    /// Older ledgers decode without this field and migrate on their next save.
    var checkpointID: UUID?
    /// Durable identity of admitted content; metadata-only checkpoints retain it.
    var reportRevision: UUID?
    var cursors: [String: Cursor] = [:]
    var entries: [Entry] = []
    var quotas: [String: Quota] = [:]
    var started = Date()
    var lastPoll: Date?
    var lastAccount: Account?
    var historyCursors: [String: Cursor]?
    var historyImportedAt: Date?
    var historyError: String?
    var plans: [String: PlanObservation]?
    var accounts: [String: Account]?
    var eventIDs: Set<String>?
    var dedupVersion: Int?
    var eventIndexReady: Bool?
    var duplicateEvents: Int?
    var unkeyedEvents: Int?
    /// Records refused admission to the totals, by reason. Never deleted data:
    /// a held record is counted and named, never silently dropped or shown.
    var integrity: IntegrityReport?
    var costMetadataVersion: Int?
    var costRecoverySummary: String?
    var claudeCounters: [String: Tokens]?
    var claudeFileChecks: [String: ClaudeFileCheck]?
    var claudeCursors: [String: ClaudeCursor]?
    var openCodeCursors: [String: OpenCodeUsage.Watermark]?
    var openCodePending: [String: Set<String>]?
    var sourceErrors: [String: String]?
    var sourceErrorPaths: [String: Set<String>]?
}
struct Snapshot {
    var contentID: UUID?
    var entries: [Entry] = []
    var quotas: [Quota] = []
    var account: Account?
    var updated: Date?
    var started = Date()
    var error: String?
    var files = 0
    var historyImportedAt: Date?
    var plans: [PlanObservation] = []
    var accounts: [Account] = []
    var additions: [Entry] = []
    var integrity: IntegrityReport?
}
final class UsageScanner {
    let home: URL
    let grokHome: URL?
    /// Claude Code and OpenCode roots. Nil means the integration is off, which
    /// is how an uninstalled tool is represented; it is never an error.
    private(set) var claudeHome: URL?
    private(set) var openCodeHome: URL?
    /// Call only on the serial ingestion queue. Existing path-scoped cursors stay intact.
    @discardableResult func configureSources(claudeHome: URL?, openCodeHome: URL?) -> Bool {
        let changed = self.claudeHome?.path != claudeHome?.path || self.openCodeHome?.path != openCodeHome?.path
        if self.openCodeHome?.path != openCodeHome?.path { openCodeReader = nil }
        self.claudeHome = claudeHome; self.openCodeHome = openCodeHome
        return changed
    }
    /// Serial scanner ownership; never retain readers for multiple source files.
    var openCodeReader: (path: String, inode: UInt64, reader: OpenCodeUsage.Reader)?
    let stateURL: URL
    var ledger: Ledger
    var loadError: String?
    var historicalIndex: [String: Int] = [:]
    var rebuilding = false
    var lastSave = Date.distantPast
    var dirtyGeneration: UInt64 = 0
    var savedGeneration: UInt64 = 0
    var contentGeneration: UInt64 = 0
    var savedContentGeneration: UInt64 = 0
    var persistenceCount = 0
    var pendingCheckpoint: UsageCheckpoint?
    /// Optional fault injection at durable storage boundaries; unset in production.
    var checkpointWillRun: ((CheckpointPhase) throws -> Void)?
    /// File-race/read-failure seam; production leaves this unset.
    var codexReadWillRun: ((CodexReadPhase, URL) throws -> Void)?
    var lastWork = ScanWork()
    var eventIndex: EventIndex?
    var requestArchive: RequestArchive?
    var onAdmitted: ((Entry) -> Void)?
    var onSnapshot: ((Snapshot) -> Void)?
    private var lastPublication = Date.distantPast
    func currentSnapshot(now: Date = Date()) -> Snapshot {
        Snapshot(contentID: ledger.reportRevision, entries: ledger.entries, quotas: Array(ledger.quotas.values), account: ledger.lastAccount,
            updated: now, started: ledger.started, error: loadError ?? ledger.historyError,
            historyImportedAt: ledger.historyImportedAt, plans: Array((ledger.plans ?? [:]).values),
            accounts: Array((ledger.accounts ?? [:]).values), integrity: ledger.integrity)
    }
    var readAccount = true
    var requestArchiveURL: URL { stateURL.deletingPathExtension().appendingPathExtension("requests.sqlite") }
    var restoredAccounts: [String: Account] = [:]
    let iso = ISO8601DateFormatter()
    let plainISO = ISO8601DateFormatter()
    init(home: URL, stateURL: URL, retainRequests: Bool = true, grokHome: URL? = nil,
         claudeHome: URL? = nil, openCodeHome: URL? = nil) {
        self.home = home; self.stateURL = stateURL; self.grokHome = grokHome
        self.claudeHome = claudeHome; self.openCodeHome = openCodeHome
        ledger = Ledger()
        if FileManager.default.fileExists(atPath: stateURL.path) {
            do { ledger = try Self.loadLedger(from: stateURL) }
            catch { loadError = "Saved usage history could not be read; it has been preserved. " + error.localizedDescription }
        }
        if loadError == nil {
            do {
                try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                eventIndex = try EventIndex(url: stateURL.deletingPathExtension().appendingPathExtension("events.sqlite"), required: ledger.eventIndexReady == true)
                try eventIndex?.commit(ledger.eventIDs ?? [])
                if retainRequests {
                    requestArchive = try RequestArchive(url: requestArchiveURL)
                    try requestArchive?.acknowledge { id in
                        guard let found = eventIndex?.contains(id) else { throw RequestArchive.failure("Event identity could not be verified") }
                        return found
                    }
                }
                if ledger.eventIndexReady != true { markDirty() }
                ledger.eventIDs = []
                ledger.eventIndexReady = true
            } catch { loadError = error.localizedDescription }
        }
        ledger.lastPoll = nil
        if loadError == nil && ledger.reportRevision == nil { markDirty() }
        compactHistoricalEntries()
        recoverMissingPricingDays()
        if !FileManager.default.fileExists(atPath: stateURL.path) { markDirty() }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }
    func recoverMissingPricingDays() {
        for index in ledger.entries.indices {
            let previous = ledger.entries[index]
            UsageMetadata.recoverPricingDay(&ledger.entries[index])
            if ledger.entries[index] != previous { markDirty() }
        }
    }
    static func restoreKey(_ entry: Entry) -> String {
        "\(Int64((entry.date.timeIntervalSince1970 * 1000).rounded()))|\(entry.session)|\(entry.model)|\(entry.tokens.input)|\(entry.tokens.cached)|\(entry.tokens.output)|\(entry.tokens.reasoning)"
    }
    private func historyKey(_ entry: Entry) -> String {
        let day = Calendar.current.startOfDay(for: entry.date).timeIntervalSince1970
        // Harness and project are part of the key. Without them a day bucket
        // would merge turns from different tools or different projects and keep
        // only the first one's attribution, which is exactly the blurring this
        // ledger is meant to avoid.
        return "\(day)|\(entry.session)|\(entry.model)|\(entry.account?.id ?? "unknown")|\(entry.provider ?? "unknown")|\(entry.harness ?? "unknown")|\(Project.key(entry.projectPath) ?? "unknown")|\(entry.effort ?? "unknown")|\(entry.contextBand ?? "unknown")|\(entry.tokens.cacheWrite == nil ? "unknown" : "known")|\(entry.costMetadataVersion ?? 0)|\(UsageMetadata.aggregationKey(entry))"
    }
    private func admitHistorical(_ entry: Entry) {
        let key = historyKey(entry)
        if let index = historicalIndex[key] {
            ledger.entries[index].tokens = ledger.entries[index].tokens + entry.tokens
            ledger.entries[index].sampleCount = ledger.entries[index].eventCount + entry.eventCount
            if let added = entry.costUsdTicks {
                ledger.entries[index].costUsdTicks = (ledger.entries[index].costUsdTicks ?? 0) + added
            }
            if let first = entry.firstObserved {
                ledger.entries[index].firstObserved = min(ledger.entries[index].firstObserved ?? first, first)
            }
            ledger.entries[index].lastObserved = max(ledger.entries[index].lastObserved ?? ledger.entries[index].date, entry.lastObserved ?? entry.date)
        } else {
            var bucket = entry
            bucket.date = Calendar.current.startOfDay(for: entry.date)
            bucket.sampleCount = entry.eventCount
            bucket.bucket = "day"
            bucket.recordID = nil; bucket.turnID = nil; bucket.requestInputTokens = nil
            bucket.lastObserved = entry.lastObserved ?? entry.date
            historicalIndex[key] = ledger.entries.count
            ledger.entries.append(bucket)
        }
    }
    private func compactHistoricalEntries() {
        let old = ledger.entries
        ledger.entries = []; historicalIndex = [:]
        let boundary = Calendar.current.startOfDay(for: ledger.started)
        for entry in old {
            if entry.date < boundary { admitHistorical(entry) }
            else { ledger.entries.append(entry) }
        }
        if old != ledger.entries { markDirty() }
    }
    func rebuildHistoricalIndex() {
        historicalIndex = [:]
        for (index, entry) in ledger.entries.enumerated() where entry.bucket == "day" { historicalIndex[historyKey(entry)] = index }
    }
    func consume(_ data: Data, session: String, cursor: inout Cursor, account: Account?, poll: Date, historical: Bool = false, continuous: Bool = true) {
        // Ignore prompt-bearing records without decoding them.
        guard ["token_count", "turn_context", "session_meta"].contains(where: { data.range(of: Data($0.utf8)) != nil }) else { return }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["payload"] as? [String: Any] else { return }
        if root["type"] as? String == "session_meta" {
            let sourceSession = payload["id"] as? String
            if let prior = cursor.sourceSession, sourceSession != prior {
                let offset = cursor.offset, continuity = cursor.continuity, aliasWitness = cursor.aliasWitness
                let gap = cursor.continuityGap ?? (cursor.reconciliation == nil ? nil : "Source continuity is incomplete across a session change; prior totals retained.")
                cursor = Cursor(offset: offset)
                cursor.continuity = continuity; cursor.continuityGap = gap; cursor.aliasWitness = aliasWitness
            }
            cursor.sourceSession = sourceSession
            if let sourceSession, let prior = cursor.reconciliation?.session, sourceSession != prior {
                cursor.continuityGap = "Source was replaced by a different session; prior totals retained."
                cursor.reconciliation = nil
                cursor.admittedBoundary = nil
            }
            cursor.provider = payload["model_provider"] as? String
            cursor.harness = Harness.codex(originator: payload["originator"])
            cursor.projectPath = Project.path(payload["cwd"])
            return
        }
        if root["type"] as? String == "turn_context" {
            cursor.model = payload["model"] as? String ?? "Unknown model"
            cursor.turnID = payload["turn_id"] as? String
            let reasoning = payload["reasoning"] as? [String: Any]
            let effort = (payload["effort"] as? String ?? payload["reasoning_effort"] as? String ?? reasoning?["effort"] as? String)?.lowercased()
            cursor.requestedService = UsageMetadata.service(payload["service_tier"])
            cursor.effort = effort.flatMap { ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"].contains($0) ? $0 : nil }
            if let provider = payload["model_provider"] as? String { cursor.provider = provider }
            if let cwd = Project.path(payload["cwd"]) { cursor.projectPath = cwd }
            return
        }
        guard root["type"] as? String == "event_msg", payload["type"] as? String == "token_count",
              let stamp = root["timestamp"] as? String, let date = iso.date(from: stamp) ?? plainISO.date(from: stamp) else { return }
        guard let info = payload["info"] as? [String: Any], let raw = info["total_token_usage"] as? [String: Any] else { return }
        let total = Tokens(raw)
        let last = (info["last_token_usage"] as? [String: Any]).map { Tokens($0) }
        let canonical = (try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])) ?? Data()
        // Preserve the established fingerprint contract, including fork deduplication.
        let identity = (cursor.turnID ?? "fallback|\(session)|\(stamp)") + "|" + String(decoding: canonical, as: UTF8.self)
        let fingerprint = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let previousFields = cursor.previousFields
        let reconciling = cursor.reconciliation != nil
        let recoveredBoundary = cursor.reconciliation.map { recovery in
            let matches = recovery.fingerprint.map { $0 == fingerprint && recovery.session == cursor.sourceSession } ??
                ((ledger.eventIDs?.contains(fingerprint) == true || eventIndex?.contains(fingerprint) == true))
            return matches && recovery.previous == total &&
                (recovery.covered.map { total.input >= $0.total.input && total.output >= $0.total.output && date >= $0.date } ?? true)
        } ?? false
        if recoveredBoundary { cursor.reconciliation = nil }
        var resumedAtVerifiedBoundary = false
        let delta: Tokens
        if reconciling {
            // A replayed earlier snapshot is not a safe cumulative baseline:
            // A100/B200 admitted, then A100/C300 must add only C's last100.
            let rawLast = info["last_token_usage"] as? [String: Any]
            let complete = rawLast?["input_tokens"] as? Int != nil && rawLast?["output_tokens"] as? Int != nil
            let covered = cursor.reconciliation?.covered ?? cursor.admittedBoundary
            let disjoint = covered.map { old in
                guard old.session != nil, old.session == cursor.sourceSession, let last else { return false }
                return date >= old.date && last.input >= 0 && last.output >= 0 &&
                    total.input >= last.input && total.output >= last.output &&
                    total.input - last.input >= old.total.input && total.output - last.output >= old.total.output
            } ?? (cursor.reconciliation == nil)
            let legacyFloor = cursor.reconciliation?.legacy == true ? cursor.reconciliation?.previous : nil
            let beyondLegacy = legacyFloor.map { floor in
                guard let last else { return false }
                return total.input >= last.input && total.output >= last.output &&
                    total.input - last.input >= floor.input && total.output - last.output >= floor.output
            } ?? true
            // If the old anchor is gone, a later dated request on a verified
            // append can establish a new boundary without erasing the old gap.
            resumedAtVerifiedBoundary = cursor.reconciliation?.resume.map { observed in
                guard let verifiedAt = observed.verifiedAt, let last,
                      observed.session != nil, observed.session == cursor.sourceSession else { return false }
                return continuous && date > verifiedAt && date <= poll && date > observed.date &&
                    last.input >= 0 && last.output >= 0 && total.input >= last.input && total.output >= last.output &&
                    total.input - last.input >= observed.total.input && total.output - last.output >= observed.total.output &&
                    (covered.map { date >= $0.date } ?? true)
            } ?? false
            delta = complete && ((disjoint && beyondLegacy) || resumedAtVerifiedBoundary) ? (last ?? Tokens()) : Tokens()
        } else if let old = cursor.previous {
            if total == old { return }
            delta = total.input >= old.input && total.output >= old.output ? total.delta(from: old) : (last ?? Tokens())
        } else {
            // A fork can inherit a parent's cumulative counters: only admit its last request.
            delta = last ?? Tokens()
        }
        cursor.previous = total
        cursor.previousFields = UsageMetadata.recordedFields(raw)
        cursor.lastFingerprint = fingerprint
        if raw["input_tokens"] as? Int != nil, raw["output_tokens"] as? Int != nil, total.input >= 0, total.output >= 0 {
            cursor.lastObservation = CodexCounterBoundary(session: cursor.sourceSession, total: total, date: date, fingerprint: fingerprint)
        }
        let boundary = Calendar.current.startOfDay(for: ledger.started)
        guard rebuilding || (historical ? date < boundary : date >= boundary) else { return }
        if cursor.turnID == nil { ledger.unkeyedEvents = (ledger.unkeyedEvents ?? 0) + 1 }
        if let duplicate = identityKnown(fingerprint) {
            if duplicate {
                rememberCodexBoundary(total, date: date, fingerprint: fingerprint, cursor: &cursor)
                return
            }
        } else { return }
        if let rate = payload["rate_limits"] as? [String: Any] {
            if let plan = rate["plan_type"] as? String {
                let observed = continuous && !historical && (ledger.lastPoll.map { poll.timeIntervalSince($0) <= 45 && date > $0 && date <= poll && account?.id != nil && account?.id == ledger.lastAccount?.id } ?? false)
                recordPlan(plan, date: date, account: observed ? account : nil,
                    evidence: observed ? "Usage snapshot · inferred account" : "Usage snapshot · account unknown", model: cursor.model)
            }
            let name = rate["limit_name"] as? String ?? rate["limit_id"] as? String ?? "Codex"
            for window in ["primary", "secondary"] {
                guard let q = rate[window] as? [String: Any], let used = q["used_percent"] as? Double else { continue }
                let key = name + ":" + window
                if date >= (ledger.quotas[key]?.observed ?? .distantPast) {
                    ledger.quotas[key] = Quota(name: name, used: used, minutes: q["window_minutes"] as? Int ?? 0,
                        reset: (q["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }, observed: date)
                }
            }
        }
        guard delta.total > 0, rebuilding || (historical ? date < boundary : date >= boundary) else { return }
        let associated = continuous && !historical && (ledger.lastPoll.map { poll.timeIntervalSince($0) <= 45 && date > $0 && date <= poll && account != nil && account == ledger.lastAccount } ?? false)
        var entry = Entry(date: date, session: session, model: cursor.model, tokens: delta, account: associated ? account : nil)
        entry.provider = cursor.provider; entry.effort = cursor.effort; entry.costMetadataVersion = 1
        entry.harness = cursor.harness; entry.projectPath = cursor.projectPath
        entry.contextWindow = (info["model_context_window"] as? Int).flatMap { $0 > 0 ? $0 : nil }
        // Only price a known single request; cumulative deltas can span multiple calls.
        if let last, delta == last, last.input >= 0 { entry.contextBand = last.input > 272_000 ? "long" : "short" }
        let fields: [String]
        if let last, delta == last, let lastRaw = info["last_token_usage"] as? [String: Any] {
            fields = UsageMetadata.recordedFields(lastRaw)
        } else { fields = UsageMetadata.recordedFields(raw).filter { previousFields?.contains($0) == true } }
        UsageMetadata.enrich(&entry, cursor: cursor, fields: fields, fingerprint: fingerprint, last: last, info: info)
        if rebuilding { entry.account = restoredAccounts[Self.restoreKey(entry)] }
        persistAdmitted(entry, fingerprint: fingerprint, date: date)
        if loadError == nil, ledger.eventIDs?.contains(fingerprint) == true {
            if resumedAtVerifiedBoundary { cursor.reconciliation = nil; cursor.admittedBoundary = nil }
            rememberCodexBoundary(total, date: date, fingerprint: fingerprint, cursor: &cursor, allowReset: !reconciling)
        }
    }
    private func rememberCodexBoundary(_ total: Tokens, date: Date, fingerprint: String, cursor: inout Cursor, allowReset: Bool = false) {
        if let old = cursor.admittedBoundary, old.session == cursor.sourceSession,
           (date < old.date || (!allowReset && (total.input < old.total.input || total.output < old.total.output))) { return }
        let boundary = CodexCounterBoundary(session: cursor.sourceSession, total: total, date: date, fingerprint: fingerprint)
        cursor.admittedBoundary = boundary
        if cursor.reconciliation != nil { cursor.reconciliation?.covered = boundary }
    }
    func identityKnown(_ fingerprint: String) -> Bool? {
        if ledger.eventIDs == nil { ledger.eventIDs = [] }
        guard let indexed = eventIndex?.contains(fingerprint) else {
            loadError = "Historical identity lookup failed; usage history is preserved"
            return nil
        }
        if ledger.eventIDs!.contains(fingerprint) || indexed {
            ledger.duplicateEvents = (ledger.duplicateEvents ?? 0) + 1
            return true
        }
        return false
    }
    func persistAdmitted(_ entry: Entry, fingerprint: String, date: Date) {
        // Every reader admits through here, so this is the one place that has
        // to hold. A record that fails an invariant is counted and named, and
        // never reaches a total.
        markDirty()
        var entry = entry
        var violations = Integrity.violations(entry, fingerprint: fingerprint)
        if ledger.eventIDs?.contains(fingerprint) == true { violations.insert(.duplicateIdentity, at: 0) }
        let fatal = violations.filter { !$0.isRepairable }
        guard fatal.isEmpty else {
            var report = ledger.integrity ?? IntegrityReport()
            report.record(fatal)
            ledger.integrity = report
            return
        }
        if !violations.isEmpty {
            // Repairable defects leave the record's own total intact, so it is
            // counted rather than discarded, with the inconsistent field reduced.
            Integrity.repair(&entry, violations: violations)
            var report = ledger.integrity ?? IntegrityReport()
            report.recordRepair(violations)
            ledger.integrity = report
        }
        do { try requestArchive?.record(entry) }
        catch { loadError = error.localizedDescription; return }
        ledger.eventIDs!.insert(fingerprint)
        onAdmitted?(entry)
        let boundary = Calendar.current.startOfDay(for: ledger.started)
        if date < boundary { admitHistorical(entry) } else { ledger.entries.append(entry) }
        let now = Date()
        if onSnapshot != nil && now.timeIntervalSince(lastPublication) >= 0.5 {
            lastPublication = now
            onSnapshot?(currentSnapshot(now: now))
        }
    }
    func scan(historical: Bool = false, changedPaths: Set<URL>? = nil, otherTools: (() -> Void)? = nil, toolProgress: ((String, Int, Int) -> Void)? = nil, progress: ((Int, Int) -> Void)? = nil) -> Snapshot {
        lastWork = ScanWork()
        let initialCount = ledger.entries.count
        let now = Date()
        let observesAccount = changedPaths == nil || changedPaths?.isEmpty == true || Self.contains(changedPaths, root: home)
        let account = readAccount ? (observesAccount ? Account.read(home: home) : ledger.lastAccount) : nil
        if let loadError {
            var result = currentSnapshot(now: now)
            result.account = account; result.error = loadError
            return result
        }
        if let account { recordAccount(account) }
        let startDay = Calendar.current.startOfDay(for: ledger.started)
        var errors: [String] = [], count = 0
        do { try requestArchive?.begin() }
        catch { return Snapshot(contentID: ledger.reportRevision, entries: ledger.entries, error: error.localizedDescription) }
        defer { requestArchive?.rollback() }
        var paths: [URL] = []
        if let changedPaths, !changedPaths.contains(home) {
            paths = changedPaths.filter { url in
                url.pathExtension == "jsonl" && ["sessions", "archived_sessions"].contains {
                    url.path.hasPrefix(home.appendingPathComponent($0).path + "/")
                }
            }
        }
        else {
        for folder in ["sessions", "archived_sessions"] {
            let directory = home.appendingPathComponent(folder)
            if !FileManager.default.fileExists(atPath: directory.path) {
                if folder == "sessions" && grokHome == nil { errors.append("Codex sessions folder is unavailable.") }
                continue
            }
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles], errorHandler: { _, _ in errors.append("Some session folders could not be read."); return true }) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" { paths.append(url) }
        }
        }
        paths.sort { $0.lastPathComponent < $1.lastPathComponent }
        progress?(0, paths.count)
        for (index, url) in paths.enumerated() {
            defer { if (index + 1) % 25 == 0 { progress?(index + 1, paths.count) } }
            let key = codexCursorKey(url, historical: historical)
            let errorScope = "Codex · " + (historical ? "history · " : "live · ") + key
            do {
                var cursor = historical ? (ledger.historyCursors?[key] ?? Cursor()) : (ledger.cursors[key] ?? Cursor())
                let previousCursor = cursor
                try reconcileCodexAliases(url, key: key, historical: historical, cursor: &cursor)
                count += 1
                lastWork.codexFiles += 1
                try readLog(url, session: String(url.lastPathComponent.suffix(42).prefix(36)), cursor: &cursor,
                    account: account, poll: now, historical: historical, startDay: startDay)
                retainErrors(cursor.continuityGap.map { [errorScope + ": " + $0] } ?? [], for: errorScope)
                guard cursor != previousCursor else { continue }
                markMetadataDirty()
                if historical {
                    if ledger.historyCursors == nil { ledger.historyCursors = [:] }
                    ledger.historyCursors?[key] = cursor
                    if rebuilding { ledger.cursors[key] = cursor }
                } else { ledger.cursors[key] = cursor }
            } catch {
                let cursor = historical ? ledger.historyCursors?[key] : ledger.cursors[key]
                retainErrors([errorScope + ": Session could not be read: \(error.localizedDescription)"] + (cursor?.continuityGap.map { [errorScope + ": " + $0] } ?? []), for: errorScope)
            }
        }
        progress?(paths.count, paths.count)
        if Self.contains(changedPaths, root: home) { retainErrors(errors, for: "Codex", paths: changedPaths?.contains(home) == true ? nil : changedPaths?.filter { Self.contains([$0], root: home) }) }
        errors = []
        otherTools?()
        if Self.contains(changedPaths, root: grokHome) {
            toolProgress?("Grok", 0, 0)
            count += scanGrok(historical: historical, poll: now, paths: changedPaths?.contains(grokHome!) == true ? nil : changedPaths, errors: &errors, progress: { toolProgress?("Grok", $0, $1) })
            retainErrors(errors, for: "Grok", paths: changedPaths?.contains(grokHome!) == true ? nil : changedPaths?.filter { Self.contains([$0], root: grokHome) })
            errors = []
        }
        if Self.contains(changedPaths, root: claudeHome) {
            toolProgress?("Claude", 0, 0)
            count += scanClaudeCode(historical: historical, paths: changedPaths?.contains(claudeHome!) == true ? nil : changedPaths, errors: &errors, progress: { toolProgress?("Claude", $0, $1) })
            retainErrors(errors, for: "Claude", paths: changedPaths?.contains(claudeHome!) == true ? nil : changedPaths?.filter { Self.contains([$0], root: claudeHome) })
            errors = []
        }
        if Self.contains(changedPaths, root: openCodeHome) {
            toolProgress?("OpenCode", 0, 0)
            count += scanOpenCode(historical: historical, errors: &errors, progress: { toolProgress?("OpenCode", $0, $1) })
            retainErrors(errors, for: "OpenCode")
            errors = []
        }
        errors = Array((ledger.sourceErrors ?? [:]).values)
        if historical {
            markMetadataDirty()
            ledger.dedupVersion = 1
            ledger.historyImportedAt = Date()
            ledger.historyError = errors.isEmpty ? nil : Array(Set(errors)).joined(separator: " ")
        }
        if let loadError { return Snapshot(contentID: ledger.reportRevision, entries: ledger.entries, account: account, error: loadError) }
        do { try requestArchive?.commit() }
        catch { loadError = error.localizedDescription; return Snapshot(contentID: ledger.reportRevision, entries: ledger.entries, error: loadError) }
        if observesAccount {
            if ledger.lastAccount != account { markMetadataDirty() }
            ledger.lastPoll = now; ledger.lastAccount = account
        }
        do {
            try saveIfNeeded(now: now, force: historical)
        } catch { errors.append("Usage history could not be saved: \(error.localizedDescription)") }
        return Snapshot(contentID: ledger.reportRevision, entries: ledger.entries, quotas: ledger.quotas.values.sorted { $0.name < $1.name }, account: account,
            updated: now, started: ledger.started, error: errors.isEmpty ? ledger.historyError : Array(Set(errors)).joined(separator: " "), files: count, historyImportedAt: ledger.historyImportedAt, plans: Array((ledger.plans ?? [:]).values).sorted { $0.lastSeen > $1.lastSeen }, accounts: Array((ledger.accounts ?? [:]).values).sorted { $0.label < $1.label }, additions: historical ? [] : Array(ledger.entries.dropFirst(initialCount)), integrity: ledger.integrity)
    }
}
