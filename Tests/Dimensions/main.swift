import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) { precondition(condition(), message) }

func entry(harness: String?, provider: String?, project: String?, model: String = "gpt-5",
           input: Int = 100, output: Int = 10) -> Entry {
    var tokens = Tokens()
    tokens.input = input
    tokens.output = output
    var row = Entry(date: Date(), session: "s", model: model, tokens: tokens, account: nil)
    row.harness = harness
    row.provider = provider
    row.projectPath = project
    return row
}

check(ModelIdentity.unknown == "Unknown model", "missing model names share one explicit label")
let unnamedModel = entry(harness: "OpenCode", provider: "lmstudio", project: "/Users/x/dev/alpha", model: ModelIdentity.unknown)
let namedModel = entry(harness: "OpenCode", provider: "lmstudio", project: "/Users/x/dev/alpha")
check(CostCoverage.build([unnamedModel]).dimensions.first { $0.id == "model" }?.knownRecords == 0,
      "an omitted model is not counted as a known model")
check(CostCoverage.build([namedModel]).dimensions.first { $0.id == "model" }?.knownRecords == 1,
      "a named model is counted as known")
check(CostCoverage.build([entry(harness: nil, provider: nil, project: nil)]).byHarness[DimensionReport.unattributed] != nil,
      "coverage groups a missing tool under the same unattributed label as dimension reports")
do {
    var data: [String: Any] = [
        "role": "assistant", "providerID": "lmstudio",
        "tokens": ["input": 10, "output": 2, "reasoning": 0, "cache": ["read": 0, "write": 0]],
        "path": ["cwd": "/Users/x/dev/alpha"], "cost": 0,
        "time": ["created": 1_769_555_059_217]
    ]
    check(OpenCodeUsage.turn(id: "m", session: "s", data: data)?.model == ModelIdentity.unknown,
          "OpenCode without a model id uses the shared unknown-model label")
    data["modelID"] = ""
    check(OpenCodeUsage.turn(id: "m", session: "s", data: data)?.model == ModelIdentity.unknown,
          "an empty OpenCode model id is unknown, not a blank model")
}
print("PASS: omitted models and tools use the shared unknown and unattributed labels")

// A harness that is not a provider ------------------------------------------
// One harness reaching several providers is the fact the single `provider`
// field could not express. This is the reason the dimension exists.
let mixed = [
    entry(harness: "OpenCode", provider: "openai", project: "/Users/x/dev/alpha"),
    entry(harness: "OpenCode", provider: "anthropic", project: "/Users/x/dev/alpha"),
    entry(harness: "Codex Desktop", provider: "openai", project: "/Users/x/dev/alpha"),
]
check(DimensionReport.providers(ofHarness: "OpenCode", in: mixed) == ["anthropic", "openai"],
      "one harness must resolve to several providers")
print("PASS: one harness resolves to multiple providers")

check(DimensionReport.harnesses(ofProvider: "openai", in: mixed) == ["Codex Desktop", "OpenCode"],
      "one provider must resolve to several harnesses")
print("PASS: one provider resolves to multiple harnesses")

// Four harness values group independently of provider.
let four = [
    entry(harness: "Codex Desktop", provider: "openai", project: "/Users/x/dev/alpha"),
    entry(harness: "Grok", provider: "xai", project: nil),
    entry(harness: "Claude Code", provider: "anthropic", project: "/Users/x/dev/beta"),
    entry(harness: "OpenCode", provider: "openai", project: "/Users/x/dev/beta"),
]
let harnessRows = DimensionReport.byHarness(four)
check(harnessRows.count == 4, "expected four harness rows, got \(harnessRows.count)")
check(Set(harnessRows.map(\.name)) == ["Codex Desktop", "Grok", "Claude Code", "OpenCode"],
      "harness grouping must keep all four values distinct")
print("PASS: a report groups by harness across four values")

// Project attribution --------------------------------------------------------
// macOS filesystems are case-insensitive, so the same directory appears under
// several spellings. They must total as one project, not two.
let spelled = [
    entry(harness: "Codex Desktop", provider: "openai", project: "/Users/x/dev/alpha", input: 100),
    entry(harness: "Codex Desktop", provider: "openai", project: "/Users/x/Dev/alpha", input: 50),
    entry(harness: "Codex Desktop", provider: "openai", project: "/Users/x/dev/alpha/", input: 25),
]
let projects = DimensionReport.byProject(spelled)
check(projects.count == 1, "case and trailing-slash variants must collapse to one project, got \(projects.count)")
check(projects[0].tokens.input == 175, "collapsed project must total every spelling, got \(projects[0].tokens.input)")
check(projects[0].name == "alpha", "project display name must be the directory name, got \(projects[0].name)")
check(projects[0].paths.count == 2, "both observed spellings must be retained as evidence, got \(projects[0].paths)")
print("PASS: case and trailing-slash project spellings collapse to one project")
print("PASS: collapsed project retains every observed path as evidence")

// Unattributed is explicit, never zero and never invented ---------------------
let partial = [
    entry(harness: "Codex Desktop", provider: "openai", project: "/Users/x/dev/alpha", input: 10),
    entry(harness: nil, provider: nil, project: nil, input: 7),
]
let partialProjects = DimensionReport.byProject(partial)
check(partialProjects.count == 2, "a missing project must produce its own row")
let unattributed = partialProjects.first { !$0.attributed }
check(unattributed?.name == DimensionReport.unattributed, "a missing project must be labelled, not blank")
check(unattributed?.tokens.input == 7, "unattributed usage must be counted, not discarded")
check(unattributed?.paths.isEmpty == true, "an unattributed row must not invent a path")
print("PASS: missing project attribution is reported as unattributed, not zero")

// Rejection of implausible values --------------------------------------------
check(Project.path("relative/path") == nil, "a relative path is not a project")
check(Project.path("") == nil, "an empty path is not a project")
check(Project.path("/") == nil, "the filesystem root is not a project")
check(Project.path(42) == nil, "a non-string is not a project")
check(Harness.codex(originator: "") == nil, "an empty originator is not a harness")
check(Harness.codex(originator: 7) == nil, "a non-string originator is not a harness")
check(Harness.codex(originator: "Codex Desktop") == "Codex Desktop", "a real originator is the harness label")
print("PASS: implausible project and harness values are rejected rather than defaulted")

// Upgrade compatibility ------------------------------------------------------
// A ledger written before these fields existed must still decode, with the new
// dimensions absent rather than defaulted.
let legacy = """
{"date":760000000,"session":"old","model":"gpt-5","tokens":{"input":5,"cached":0,"output":1,"reasoning":0}}
"""
let decoded = try JSONDecoder().decode(Entry.self, from: Data(legacy.utf8))
check(decoded.harness == nil, "a legacy entry must not gain an invented harness")
check(decoded.projectPath == nil, "a legacy entry must not gain an invented project")
check(decoded.tokens.input == 5, "a legacy entry must keep its counters")
print("PASS: ledger entries written before these dimensions still decode")

print("PASS: dimension report suite complete")

// End-to-end: the scanner must extract both dimensions from real record shapes --
// The unit checks above use constructed entries. These drive the actual scanner
// with the record shapes observed in Codex session logs.
let temp = FileManager.default.temporaryDirectory.appendingPathComponent("TokenBar-dim-" + UUID().uuidString)
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }
let scanner = UsageScanner(home: temp, stateURL: temp.appendingPathComponent("state.json"))
let stamp = ISO8601DateFormatter()
let at = Date()

func record(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

let meta = record(["timestamp": stamp.string(from: at), "type": "session_meta", "payload": [
    "session_id": "abc", "cwd": "/Users/x/dev/alpha", "originator": "Codex Desktop",
    "cli_version": "1.0.0", "model_provider": "openai",
    "git": ["branch": "main", "commit_hash": "deadbeef"],
]])
let context = record(["timestamp": stamp.string(from: at), "type": "turn_context", "payload": [
    "turn_id": "turn-1", "cwd": "/Users/x/dev/alpha", "model": "gpt-5", "effort": "high",
]])
let usage = record(["timestamp": stamp.string(from: at), "type": "event_msg", "payload": [
    "type": "token_count", "info": [
        "total_token_usage": ["input_tokens": 200, "cached_input_tokens": 50, "output_tokens": 20],
        "last_token_usage": ["input_tokens": 200, "cached_input_tokens": 50, "output_tokens": 20],
    ]]])

var live = Cursor()
scanner.consume(meta, session: "abc", cursor: &live, account: nil, poll: at)
scanner.consume(context, session: "abc", cursor: &live, account: nil, poll: at)
scanner.consume(usage, session: "abc", cursor: &live, account: nil, poll: at)

check(scanner.ledger.entries.count == 1, "expected one admitted entry, got \(scanner.ledger.entries.count)")
let admitted = scanner.ledger.entries[0]
check(admitted.harness == "Codex Desktop", "scanner must carry the originator as harness, got \(admitted.harness ?? "nil")")
check(admitted.projectPath == "/Users/x/dev/alpha", "scanner must carry cwd as the project, got \(admitted.projectPath ?? "nil")")
check(admitted.provider == "openai", "provider must remain its own dimension, got \(admitted.provider ?? "nil")")
check(admitted.effort == "high", "reasoning setting must remain its own dimension, got \(admitted.effort ?? "nil")")
print("PASS: scanner extracts harness and project from session_meta")
print("PASS: harness, provider, model and reasoning stay four separate dimensions end to end")

// A session without an originator must not be labelled with a guessed harness.
let bare = record(["timestamp": stamp.string(from: at), "type": "session_meta",
                   "payload": ["session_id": "bare", "model_provider": "openai"]])
var bareCursor = Cursor()
scanner.consume(bare, session: "bare", cursor: &bareCursor, account: nil, poll: at)
check(bareCursor.harness == nil, "an absent originator must leave the harness unknown")
check(bareCursor.projectPath == nil, "an absent cwd must leave the project unknown")
print("PASS: an absent originator or cwd stays unknown rather than defaulting to Codex")

// The report surface a person actually sees --------------------------------
// Plumbing that never reaches a view is storage without benefit, and project
// paths are a privacy surface. These prove the dimensions reach the report.
var reportEntries: [Entry] = []
for _ in 0..<2 {
    reportEntries.append(entry(harness: "Codex Desktop", provider: "openai",
                               project: "/Users/x/dev/alpha", input: 100, output: 40))
}
reportEntries.append(entry(harness: "Codex Desktop", provider: "openai",
                           project: "/Users/x/Dev/alpha", input: 10, output: 5))
reportEntries.append(entry(harness: "Grok", provider: "xai", project: nil, input: 10, output: 3))

var reportQuery = UsageQuery()
reportQuery.period = 1
let report = UsageReport.build(entries: reportEntries, query: reportQuery, catalog: [:])

check(report.projects.count == 2, "expected one project row plus unattributed, got \(report.projects.count)")
let alpha = report.projects.first { $0.title == "alpha" }
check(alpha != nil, "the project row must be named for its directory")
check(alpha?.tokens.output == 85, "case-variant spellings must total into one project row, got \(alpha?.tokens.output ?? -1)")
check(report.projects.contains { $0.title == DimensionReport.unattributed }, "usage without a project must still appear")
print("PASS: the usage report groups output by project")

check(report.harnesses.count == 2, "expected two tool rows, got \(report.harnesses.count)")
check(report.harnesses.map(\.title).sorted() == ["Codex Desktop", "Grok"], "tool rows must be named for the harness")
check(report.harnesses.first { $0.title == "Grok" }?.subtitle == "Provider: xai",
      "a tool row must show its provider without becoming the provider")
print("PASS: the usage report groups output by tool and keeps provider distinct")

let projectTotal = report.projects.reduce(0) { $0 + $1.tokens.output }
check(projectTotal == report.totals.output,
      "project rows must account for every token, got \(projectTotal) of \(report.totals.output)")
let harnessTotal = report.harnesses.reduce(0) { $0 + $1.tokens.output }
check(harnessTotal == report.totals.output,
      "tool rows must account for every token, got \(harnessTotal) of \(report.totals.output)")
print("PASS: project and tool rows each account for every recorded token")

// Context headroom ----------------------------------------------------------
// Occupancy must only exist where it is genuinely measurable. A cumulative
// delta can span several calls, so dividing it by one window would overstate it.
var single = entry(harness: "Codex Desktop", provider: "openai", project: "/Users/x/dev/alpha")
single.contextWindow = 400_000
single.requestInputTokens = 100_000
check(single.contextOccupancy != nil, "a single request with a known window must report occupancy")
check(abs((single.contextOccupancy ?? 0) - 0.25) < 0.0001, "occupancy must be input over window, got \(single.contextOccupancy ?? -1)")
print("PASS: context occupancy is measured from a single request against its reported window")

var noWindow = single
noWindow.contextWindow = nil
check(noWindow.contextOccupancy == nil, "no reported window means no occupancy, not a guess")
var cumulative = single
cumulative.requestInputTokens = nil
check(cumulative.contextOccupancy == nil, "a cumulative delta must not be divided by one window")
var zeroWindow = single
zeroWindow.contextWindow = 0
check(zeroWindow.contextOccupancy == nil, "a zero window must not divide")
print("PASS: context occupancy stays unavailable rather than approximated")

var overfull = single
overfull.requestInputTokens = 500_000
check(overfull.contextOccupancy == 1, "occupancy is capped at the full window, got \(overfull.contextOccupancy ?? -1)")
print("PASS: context occupancy is capped at one rather than exceeding the window")

// The scanner must capture the window from the same record as the counters.
let windowed = record(["timestamp": stamp.string(from: at), "type": "event_msg", "payload": [
    "type": "token_count", "info": [
        "model_context_window": 272_000,
        "total_token_usage": ["input_tokens": 900, "cached_input_tokens": 100, "output_tokens": 30],
        "last_token_usage": ["input_tokens": 900, "cached_input_tokens": 100, "output_tokens": 30],
    ]]])
var windowCursor = Cursor()
scanner.consume(meta, session: "win", cursor: &windowCursor, account: nil, poll: at)
scanner.consume(context, session: "win", cursor: &windowCursor, account: nil, poll: at)
scanner.consume(windowed, session: "win", cursor: &windowCursor, account: nil, poll: at)
let withWindow = scanner.ledger.entries.last
check(withWindow?.contextWindow == 272_000, "scanner must carry the reported context window, got \(withWindow?.contextWindow.map(String.init) ?? "nil")")
print("PASS: scanner carries the harness-reported context window")

// A ledger written before the field must not gain an invented window.
let older = try JSONDecoder().decode(Entry.self, from: Data(legacy.utf8))
check(older.contextWindow == nil, "a legacy entry must not gain an invented context window")
check(older.contextOccupancy == nil, "a legacy entry must not report occupancy")
print("PASS: entries predating the context window field report no occupancy")

// Historical aggregation must not blur the new dimensions -------------------
// Day buckets merge entries that share a key. If harness and project are not
// part of that key, two projects collapse into one bucket and the second one's
// attribution is lost.
let aggTemp = FileManager.default.temporaryDirectory.appendingPathComponent("TokenBar-agg-" + UUID().uuidString)
try FileManager.default.createDirectory(at: aggTemp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: aggTemp) }
let aggScanner = UsageScanner(home: aggTemp, stateURL: aggTemp.appendingPathComponent("agg.json"))

let yesterday = Calendar.current.date(byAdding: .day, value: -3, to: Date())!
func historical(_ project: String?, harness: String?, output: Int) -> Data {
    record(["timestamp": stamp.string(from: yesterday), "type": "event_msg", "payload": [
        "type": "token_count", "info": [
            "total_token_usage": ["input_tokens": output * 10, "output_tokens": output],
            "last_token_usage": ["input_tokens": output * 10, "output_tokens": output],
        ]]])
}
func metaFor(_ project: String, harness: String) -> Data {
    record(["timestamp": stamp.string(from: yesterday), "type": "session_meta",
            "payload": ["session_id": "agg", "cwd": project, "originator": harness, "model_provider": "openai"]])
}
let ctx = record(["timestamp": stamp.string(from: yesterday), "type": "turn_context",
                  "payload": ["turn_id": "t-agg", "model": "gpt-5"]])

// One session id, same day and model, two different projects.
var alphaCursor = Cursor()
aggScanner.consume(metaFor("/Users/x/dev/alpha", harness: "Codex Desktop"), session: "agg", cursor: &alphaCursor, account: nil, poll: yesterday, historical: true)
aggScanner.consume(ctx, session: "agg", cursor: &alphaCursor, account: nil, poll: yesterday, historical: true)
aggScanner.consume(historical(nil, harness: nil, output: 10), session: "agg", cursor: &alphaCursor, account: nil, poll: yesterday, historical: true)

var betaCursor = Cursor()
aggScanner.consume(metaFor("/Users/x/dev/beta", harness: "Codex Desktop"), session: "agg", cursor: &betaCursor, account: nil, poll: yesterday, historical: true)
aggScanner.consume(ctx, session: "agg", cursor: &betaCursor, account: nil, poll: yesterday, historical: true)
aggScanner.consume(historical(nil, harness: nil, output: 20), session: "agg", cursor: &betaCursor, account: nil, poll: yesterday, historical: true)

let buckets = aggScanner.ledger.entries.filter { $0.bucket == "day" }
let bucketProjects = Set(buckets.compactMap { Project.name($0.projectPath) })
check(bucketProjects == ["alpha", "beta"],
      "day buckets must keep projects apart, got \(bucketProjects.sorted())")
print("PASS: historical day buckets do not merge separate projects")

let toolQuery = UsageQuery(period: 1, harness: ClaudeCodeUsage.harness)
let claudeReport = UsageReport.build(entries: four, query: toolQuery, catalog: [:], now: Date().addingTimeInterval(1))
check(claudeReport.entries.count == 1 && claudeReport.entries[0].harness == ClaudeCodeUsage.harness, "Tool filter must scope the actual report entries")
check(claudeReport.totals == four[2].tokens && claudeReport.harnesses.count == 1, "Tool-scoped totals and breakdown must agree")
check(claudeReport.timeline.points.last?.tokens == four[2].tokens, "Timeline must use the same tool scope as totals")
print("PASS: tool filter scopes history totals, breakdowns and timeline together")

let multiProviderReport = UsageReport.build(entries: mixed, query: UsageQuery(period: 1), catalog: [:], now: Date().addingTimeInterval(1))
check(multiProviderReport.harnesses.first(where: { $0.title == "OpenCode" })?.subtitle == "Providers: anthropic, openai", "A multi-provider tool must not be labeled with only its first provider")
print("PASS: tool breakdown names all observed providers")


// Evaluation time can be injected without replacing the asynchronous publication path.
let evaluationClock = Date(timeIntervalSince1970: 1_784_563_200)
let fixedInsights = UsageInsightsModel(clock: { evaluationClock })
fixedInsights.refresh(entries: [], catalog: [:])
let clockDeadline = Date().addingTimeInterval(5)
while fixedInsights.busy && Date() < clockDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
check(fixedInsights.hasResult && fixedInsights.evaluatedAt == evaluationClock, "Usage insights must publish at the injected evaluation instant")
fixedInsights.refresh(entries: [], catalog: [:])
check(!fixedInsights.busy, "Unchanged fixed-clock input must remain settled")
print("PASS: fixed evaluation clock survives asynchronous usage-insight publication and cache reuse")

do {
    let now = Date(), calendar = Calendar.current
    let today = calendar.startOfDay(for: now)
    func record(_ days: Int, _ output: Int, fields: [String] = ["output_tokens"]) -> Entry {
        var entry = Entry(date: calendar.date(byAdding: .day, value: days, to: today)!,
                          session: "comparison", model: "synthetic", tokens: Tokens(["output_tokens": output]))
        entry.tokenFields = fields
        return entry
    }
    func summary(_ entries: [Entry]) -> UsageInsightsSummary {
        UsageInsightsSummary.build(entries: entries, catalog: [:], now: now)
    }
    let prior = record(-14, 100), recent = record(-7, 150)
    let changed = summary([prior, recent])
    check(changed.outputChangeClaim == .changed(percent: 50, recent: 150, previous: 100),
          "A complete pair of weeks is a percent claim, not a reconstructed view branch")
    check(changed.outputChangeHeadline { "\($0)" } == "50.0% above the prior period",
          "Percent copy is owned by the claim")
    check(changed.outputChangeEvidence { "\($0)" } == "150 output tokens in the last seven full days · 100 in the preceding seven.",
          "Supporting totals remain evidence under the percent")
    check(summary([prior, record(-1, 100)]).outputChangeHeadline { "\($0)" } == "Unchanged between recorded periods",
          "A measured zero change is unchanged, not unavailable")
    check(summary([prior]).outputChangeClaim == .missingPeriod,
          "A missing week is not a zero percent")
    check(summary([prior]).outputChangeHeadline { "\($0)" }
          == "Comparison unavailable: one or both periods have no local records.",
          "Missing-period copy stays unavailable")
    var missing = recent; missing.tokenFields = ["input_tokens"]
    check(summary([prior, missing]).outputChangeClaim == .missingOutput(1),
          "Unknown output counters are not a percent")
    check(summary([record(-8, 0), recent]).outputChangeClaim == .zeroBaseline(recent: 150),
          "A zero baseline is undefined, not 0%")
    check(summary([record(-8, 0), recent]).outputChangeHeadline { "\($0)" }
          == "150 recorded output tokens after a prior period with zero recorded output. A percentage change is undefined.",
          "Zero-baseline copy keeps the recent total without inventing a percent")
    check(changed.peakContextClaim == .unavailable, "No measurable context is unavailable, not 0%")
    check(changed.peakContextHeadline == "Context utilization unavailable: no records contain both request input and a known context window.",
          "Peak-context copy is owned by the claim")
    check(changed.peakContextEvidence == nil, "Unavailable peak context has no sample count")
    check(changed.cacheShareCaption == nil, "Counters without presence metadata cannot establish a cache-share sentence")
}
print("PASS: insight claims distinguish percent, missing period, unknown counters, zero baseline and unavailable peak context")
