import Foundation
import SwiftUI

func check(_ condition: @autoclosure () -> Bool, _ message: String) { precondition(condition(), message) }

let good = String(repeating: "a", count: 64)
func entry(input: Int = 100, cached: Int = 10, output: Int = 20, reasoning: Int = 5,
           cacheWrite: Int? = nil, date: Date = Date(), project: String? = "/Users/x/dev/alpha",
           harness: String? = "Codex Desktop", provider: String? = "openai",
           fingerprint: String = good) -> Entry {
    var tokens = Tokens()
    tokens.input = input; tokens.cached = cached; tokens.output = output
    tokens.reasoning = reasoning; tokens.cacheWrite = cacheWrite
    var row = Entry(date: date, session: "s", model: "gpt-5", tokens: tokens, account: nil)
    row.projectPath = project; row.harness = harness; row.provider = provider
    row.recordID = fingerprint
    return row
}

// A well-formed record is admissible ---------------------------------------
check(Integrity.violations(entry(), fingerprint: good).isEmpty, "a well-formed record must be admissible")
print("PASS: a well-formed record passes every invariant")

do {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TokenBar-private-cache-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("cache.json")
    try PrivateCache.write(Data("secret".utf8), to: url)
    let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber
    check(permissions.intValue == 0o600, "Published private cache must be 0600, not chmod after a world-readable write")
    let body = try String(contentsOf: url, encoding: .utf8)
    check(body == "secret", "Published bytes must match")
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".pending-") }
    check(leftovers.isEmpty, "A successful publish must not leave the pending file")
}
print("PASS: private cache publish is 0600 without a leftover pending file")

// Each invariant refuses its own violation ---------------------------------
func refuses(_ row: Entry, _ expected: IntegrityViolation, _ fingerprint: String = good) -> Bool {
    Integrity.violations(row, fingerprint: fingerprint).contains(expected)
}
check(refuses(entry(fingerprint: good), .unboundIdentity, String(repeating: "c", count: 64)),
      "a record whose stored identity differs from its admitted identity must be refused")
print("PASS: a record cannot be admitted under an identity it does not carry")
check(refuses(entry(input: -1), .negativeCounter), "a negative input must be refused")
check(refuses(entry(output: -5), .negativeCounter), "a negative output must be refused")
check(refuses(entry(cacheWrite: -2), .negativeCounter), "a negative cache write must be refused")
check(refuses(entry(input: 10, cached: 99), .cachedExceedsInput), "cached above input must be refused")
check(refuses(entry(output: 5, reasoning: 99), .reasoningExceedsOutput), "reasoning above output must be refused")
check(refuses(entry(input: 0, cached: 0, output: 0, reasoning: 0), .emptyUsage), "a record claiming nothing must be refused")
check(refuses(entry(fingerprint: "short"), .malformedIdentity, "short"), "a malformed identity must be refused")
check(refuses(entry(fingerprint: String(repeating: "z", count: 64)), .malformedIdentity, String(repeating: "z", count: 64)), "a non-hex identity must be refused")
check(refuses(entry(date: Date(timeIntervalSince1970: 0)), .implausibleDate), "a pre-2020 date must be refused")
check(refuses(entry(date: Date().addingTimeInterval(864_000)), .implausibleDate), "a far-future date must be refused")
check(refuses(entry(project: "relative/path"), .malformedProject), "a relative project path must be refused")
check(refuses(entry(harness: ""), .malformedLabel), "an empty tool name must be refused")
check(refuses(entry(provider: String(repeating: "p", count: 500)), .malformedLabel), "an absurd provider name must be refused")
print("PASS: every integrity invariant refuses its own violation")

// Ordinary clock skew is tolerated, because it is not falsification.
check(Integrity.violations(entry(date: Date().addingTimeInterval(600)), fingerprint: good).isEmpty,
      "ten minutes of clock skew must not be treated as falsification")
print("PASS: ordinary clock skew is tolerated rather than refused")

// Repair preserves real usage instead of discarding it ---------------------
// A tool can report more cached input than input. The record's own total is
// unaffected, so discarding it would make the total wrong to keep a detail
// tidy. The subordinate field is reduced instead, and never increased.
var inconsistent = entry(input: 100, cached: 900, output: 20, reasoning: 5)
let beforeTotal = inconsistent.tokens.total
var violations = Integrity.violations(inconsistent, fingerprint: good)
check(violations.contains(.cachedExceedsInput), "the defect must be detected")
check(violations.allSatisfy(\.isRepairable), "this defect must be repairable, not fatal")
Integrity.repair(&inconsistent, violations: violations)
check(inconsistent.tokens.cached == 100, "cached must be reduced to input, got \(inconsistent.tokens.cached)")
check(inconsistent.tokens.total == beforeTotal, "repair must not change the record's total")
check(Integrity.violations(inconsistent, fingerprint: good).isEmpty, "a repaired record must be consistent")
print("PASS: an inconsistent breakdown is repaired downward without changing the total")

var overReasoned = entry(output: 20, reasoning: 900)
let reasonViolations = Integrity.violations(overReasoned, fingerprint: good)
Integrity.repair(&overReasoned, violations: reasonViolations)
check(overReasoned.tokens.reasoning == 20, "reasoning must be reduced to output")
print("PASS: reasoning above output is reduced to output rather than discarded")

check(!IntegrityViolation.negativeCounter.isRepairable, "a negative counter is not repairable")
check(!IntegrityViolation.duplicateIdentity.isRepairable, "a duplicate is never repairable")
check(!IntegrityViolation.implausibleDate.isRepairable, "a false timestamp is not repairable")
print("PASS: defects that make a whole record untrustworthy are never repaired")

// The gate holds for every reader ------------------------------------------
// persistAdmitted is the one path all four readers use, so a hostile record
// cannot reach a total through any of them.
let temp = FileManager.default.temporaryDirectory.appendingPathComponent("TokenBar-integrity-" + UUID().uuidString)
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }
let scanner = UsageScanner(home: temp, stateURL: temp.appendingPathComponent("ledger.json"))

scanner.persistAdmitted(entry(), fingerprint: good, date: Date())
check(scanner.ledger.entries.count == 1, "a valid record must be admitted")
let before = scanner.ledger.entries.count

// The same identity twice is counted once, whatever the counters claim.
scanner.persistAdmitted(entry(input: 9999), fingerprint: good, date: Date())
check(scanner.ledger.entries.count == before, "a repeated identity must never be admitted twice")
check(scanner.ledger.integrity?.quarantined["duplicateIdentity"] == 1, "the duplicate must be counted, not ignored")
print("PASS: the same identity cannot be admitted twice through the shared gate")

// A hostile record cannot reach the totals.
let hostileFingerprint = String(repeating: "b", count: 64)
scanner.persistAdmitted(entry(input: -50, cached: 900, output: -1, fingerprint: hostileFingerprint),
                        fingerprint: hostileFingerprint, date: Date())
check(scanner.ledger.entries.count == before, "a record failing invariants must not reach the totals")
check(scanner.ledger.eventIDs?.contains(hostileFingerprint) != true, "a refused record must not claim an identity")
print("PASS: a record failing an invariant never reaches a total")

// Refusal is counted and named, never a silent deletion.
let report = scanner.ledger.integrity
check(report != nil && report!.total >= 2, "held records must be counted")
check(!report!.isClean, "a ledger with held records must not report itself clean")
check(report!.explanations.allSatisfy { $0.contains("not counted") || $0.contains("corrected detail") },
      "each reason must be stated in a sentence a person can read")
check(report!.explanations.allSatisfy { $0.count > 40 }, "a reason must explain, not just label")
print("PASS: held records are counted and explained rather than silently dropped")

// Totals exclude held records, and the interface can say so.
let admittedTotal = scanner.ledger.entries.reduce(0) { $0 + $1.tokens.total }
check(admittedTotal == 120, "totals must contain only admitted records, got \(admittedTotal)")
print("PASS: displayed totals contain only records that passed every invariant")

// A repairable record is counted, and the repair is disclosed.
let repairFingerprint = String(repeating: "d", count: 64)
scanner.persistAdmitted(entry(input: 100, cached: 900, output: 20, fingerprint: repairFingerprint),
                        fingerprint: repairFingerprint, date: Date())
check(scanner.ledger.entries.count == before + 1, "a repairable record must still be counted")
check(scanner.ledger.entries.last?.tokens.cached == 100, "the stored record must carry the repaired value")
check(scanner.ledger.integrity?.repaired["cachedExceedsInput"] == 1, "the repair must be disclosed, not hidden")
check(scanner.ledger.integrity?.isClean == false, "a ledger with repairs must not report itself clean")
print("PASS: a repaired record is counted and the repair is disclosed rather than hidden")

// Provenance ---------------------------------------------------------------
check(Provenance.estimated.isApproximate && Provenance.aggregated.isApproximate,
      "derived figures must be marked approximate")
check(!Provenance.measured.isApproximate && !Provenance.providerReported.isApproximate,
      "a reported figure must not be labelled approximate")
check(Provenance.estimated.badge == "approx." && Provenance.measured.badge == nil,
      "only approximate figures carry the badge")
for provenance in Provenance.allCases {
    check(!provenance.explanation.isEmpty && provenance.explanation.count > 40,
          "\(provenance.rawValue) must carry a real explanation")
    check(!provenance.title.isEmpty, "\(provenance.rawValue) must carry a title")
}
print("PASS: approximate figures are badged and every derivation has a plain explanation")

check(Provenance.deduplicated.deservesNotice && Provenance.converted.deservesNotice,
      "surprising derivations must raise a notice")
check(!Provenance.measured.deservesNotice, "an ordinary sum must not interrupt anyone")
print("PASS: only surprising derivations raise a notice")

// Dismissal ----------------------------------------------------------------
let suite = "local.codex-token-bar.integrity." + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let notices = ProvenanceNotices(defaults: defaults)
check(notices.shouldShow(.deduplicated), "a fresh install must explain a surprising number")
notices.silence(.deduplicated)
check(!notices.shouldShow(.deduplicated), "don't show again must take effect immediately")
check(notices.shouldShow(.converted), "silencing one explanation must not silence another")
print("PASS: don't show again silences one explanation without silencing the rest")

let reopened = ProvenanceNotices(defaults: defaults)
check(!reopened.shouldShow(.deduplicated), "don't show again must survive a restart")
check(reopened.shouldShow(.estimated), "an unrelated explanation must survive a restart too")
reopened.restoreAll()
check(reopened.shouldShow(.deduplicated), "a person must be able to get the explanations back")
print("PASS: dismissal persists across restart and can be undone")

print("PASS: integrity and provenance suite complete")

// Compact disclosure changes no admission or report state.
let states: [(String, IntegrityReport, String?)] = [
    ("clean", IntegrityReport(), nil),
    ("repaired", IntegrityReport(repaired: [IntegrityViolation.cachedExceedsInput.rawValue: 2]), "Data integrity · 2 records repaired"),
    ("excluded", IntegrityReport(quarantined: [IntegrityViolation.negativeCounter.rawValue: 1]), "Data integrity · 1 record excluded"),
    ("mixed", IntegrityReport(quarantined: [IntegrityViolation.negativeCounter.rawValue: 3], repaired: [IntegrityViolation.reasoningExceedsOutput.rawValue: 4]), "Data integrity · 3 records excluded · 4 records repaired")
]
for (name, report, expected) in states {
    let original = report
    check(IntegrityPresentation(report: report).status == expected, "Compact state must disclose exact counts: " + name)
    check(report.explanations.count == (report.total > 0 ? 1 : 0) + (report.repairedTotal > 0 ? 1 : 0), "All violation explanations remain available")
    check(report == original, "Presentation cannot change ledger integrity")
}
check(IntegrityPresentation.semantics.contains("excluded from displayed totals"), "Exclusion semantics must remain explicit")
check(IntegrityPresentation.semantics.contains("total is unchanged"), "Repair must disclose preservation of totals")
check(IntegrityPresentation.retention.contains("Nothing was deleted"), "Retention must be explicit")
print("PASS: clean, repaired-only, excluded-only and mixed compact integrity states preserve exact evidence")

MainActor.assumeIsolated {
    _ = NSApplication.shared
    let renderSuite = "local.tokenbar.integrity-render." + UUID().uuidString
    let renderDefaults = UserDefaults(suiteName: renderSuite)!
    defer { renderDefaults.removePersistentDomain(forName: renderSuite) }
    let appearance = AppearancePreferences(defaults: renderDefaults)
    appearance.websitePreset()
    for (name, report, _) in states {
        let host = NSHostingView(rootView: AppearanceHost(preferences: appearance) {
            IntegrityBanner(report: report).frame(width: 850, alignment: .leading)
        })
        let size = host.fittingSize
        check(size.height < 60, "Integrity status cannot dominate a page: " + name)
        if report.isClean { check(size.height == 0, "Clean ledger has no warning") }
        else { check(size.height > 0, "Affected totals must retain visible status") }
    }
    let host = NSHostingView(rootView: AppearanceHost(preferences: appearance) {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(states.indices, id: \.self) { index in
                IntegrityBanner(report: states[index].1)
            }
            Divider()
            IntegrityDetails(report: states[3].1)
        }.padding(24).frame(width: 850).background(Color(nsColor: .windowBackgroundColor))
    })
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    AppearanceRendering.capture(host, to: bitmap)
    try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/tests/integrity-disclosure.png"))
    window.close()
}
print("PASS: all integrity states render compactly; mixed details retain every explanation and count")
