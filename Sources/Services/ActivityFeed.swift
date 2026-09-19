import Foundation
import SQLite3

struct ActivitySource {
    var id: String
    var path: URL
    var kind: ActivityKind
    var name: String
    var model: String
    var created: Date
}
struct ActivitySources {
    static func read(home: URL) throws -> [ActivitySource] {
        guard let db = CodexCatalog.openReadOnly(CodexCatalog.database(in: home)) else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        let query = "SELECT id, rollout_path, source, thread_source, COALESCE(NULLIF(name,''), substr(title,1,120)), agent_nickname, model, COALESCE(created_at_ms, created_at * 1000) FROM threads WHERE archived=0 AND updated_at >= ? ORDER BY updated_at DESC"
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { throw CocoaError(.fileReadCorruptFile) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(Date().addingTimeInterval(-86400).timeIntervalSince1970))
        var result: [ActivitySource] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            func value(_ index: Int32) -> String { sqlite3_column_text(statement, index).map { String(cString: $0) } ?? "" }
            let kind = ActivityKind.classify(["source": value(2), "thread_source": value(3)])
            let nickname = value(5)
            result.append(ActivitySource(id: value(0), path: URL(fileURLWithPath: value(1)), kind: kind,
                name: kind == .agent && !nickname.isEmpty ? nickname : value(4).components(separatedBy: .newlines).first ?? "", model: value(6), created: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 7)) / 1000)))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw CocoaError(.fileReadUnknown) }
        return result
    }
}
/// Live reads run independently of ledger imports, history aggregation and quota requests.
final class ActivityFeed {
    private let home: URL
    private let grokHome: URL?
    private var claudeHome: URL?
    private var claudeReader = ClaudeActivityReader()
    private var configuredClaudePath: String?
    private var configurationRevision = 0
    private var claudeSources: [URL] = []
    private let publish: (ActivitySnapshot) -> Void
    private let queue = DispatchQueue(label: "local.codex-token-bar.activity", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private let reader = ActivityReader()
    private var sources: [ActivitySource] = []
    private var grokSources: [GrokActivity] = []
    private let grokMetadata = GrokActivityMetadata()
    private var codexError: String?
    private var busy = false
    private var pending = Set<URL>()
    private var needsDiscovery = false
    init(home: URL, grokHome: URL? = nil, claudeHome: URL? = nil, publish: @escaping (ActivitySnapshot) -> Void) {
        self.home = home; self.grokHome = grokHome; self.claudeHome = claudeHome; self.configuredClaudePath = claudeHome?.path; self.publish = publish
    }
    /// Main-thread configuration; reads and reader replacement remain serialized on the feed queue.
    func configureClaude(home: URL?) {
        guard configuredClaudePath != home?.path else { return }
        configuredClaudePath = home?.path
        configurationRevision += 1
        queue.async {
            self.claudeHome = home
            self.claudeSources = []
            self.claudeReader = ClaudeActivityReader()
            DispatchQueue.main.async { self.refresh() }
        }
    }
    func refresh(paths: Set<URL>? = nil) {
        guard !busy else { if let paths { pending.formUnion(paths) } else { needsDiscovery = true }; return }
        busy = true
        let revision = configurationRevision
        queue.async {
            let codexPaths = paths.map { $0.filter { $0.path.hasPrefix(self.home.path + "/") || $0 == self.home } }
            let codexChanged = codexPaths == nil || !codexPaths!.isEmpty
            if codexChanged {
                let discover = codexPaths == nil || codexPaths!.contains(self.home) ||
                    codexPaths!.contains { path in path.lastPathComponent.hasPrefix("state_5.sqlite") ||
                        !self.sources.contains(where: { source in source.path == path }) }
                if discover {
                    do { self.sources = try ActivitySources.read(home: self.home); self.codexError = nil }
                    catch { self.codexError = "Live task catalog unavailable; retained observations may be stale." }
                }
                let selected = discover ? self.sources : self.sources.filter { codexPaths!.contains($0.path) }
                for source in selected {
                    do {
                        let values = try source.path.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                        self.reader.read(source.path, modified: values.contentModificationDate ?? .distantPast,
                            size: UInt64(values.fileSize ?? 0), session: source.id, kind: source.kind,
                            name: source.name, model: source.model, created: source.created)
                    } catch { self.codexError = "Some live task logs could not be read; activity may be incomplete." }
                }
            }
            if let home = self.grokHome, UsageScanner.contains(paths, root: home) {
                let observations = GrokActivitySources.read(home: home, paths: paths, known: self.grokSources, metadata: self.grokMetadata)
                if paths == nil || paths!.contains(home) { self.grokSources = observations }
                else {
                    var current = Dictionary(self.grokSources.map { ($0.session, $0) }, uniquingKeysWith: { _, new in new })
                    for observation in observations { current[observation.session] = observation }
                    self.grokSources = Array(current.values)
                }
                for source in observations {
                    self.reader.observeGrok(session: source.session, kind: source.kind, output: source.output, date: source.date,
                        running: source.running, turn: source.turn, model: source.model, outputDate: source.outputDate, name: source.name)
                }
            }
            var result = self.reader.snapshot
            result.toolErrors[.codex] = self.codexError
            if let home = self.claudeHome {
                if paths == nil || paths!.contains(home) {
                    self.claudeSources = ClaudeCodeUsage.transcripts(home: home).filter {
                        let modified = try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                        return Date().timeIntervalSince(modified ?? .distantPast) < 300
                    }
                }
                let changed = paths?.filter { $0.path.hasPrefix(home.appendingPathComponent("projects").path + "/") && $0.pathExtension == "jsonl" }
                let selected = paths?.contains(home) == true ? self.claudeSources : (changed.map(Array.init) ?? self.claudeSources)
                for path in selected { self.claudeReader.read(path) }
                let claude = self.claudeReader.snapshot()
                result.turns.merge(claude.turns) { _, new in new }
                result.measurements.merge(claude.measurements) { _, new in new }
                result.toolErrors[.claude] = claude.error
            }
            let snapshot = result
            DispatchQueue.main.async {
                self.busy = false
                if revision == self.configurationRevision { self.publish(snapshot) }
                if self.needsDiscovery { self.needsDiscovery = false; self.pending = []; self.refresh() }
                else if !self.pending.isEmpty { let next = self.pending; self.pending = []; self.refresh(paths: next) }
            }
        }
    }
}
