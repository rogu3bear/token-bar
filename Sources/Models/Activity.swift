import Foundation

enum ActivityKind: String {
    case chat, agent, unknown
    static func classify(_ metadata: [String: Any]) -> ActivityKind {
        if metadata["thread_source"] as? String == "subagent" { return .agent }
        if metadata["thread_source"] as? String == "user" { return .chat }
        if let source = metadata["source"] as? [String: Any], source["subagent"] != nil { return .agent }
        if let source = metadata["source"] as? String {
            if source == "subagent" { return .agent }
            if ["cli", "vscode", "exec", "appServer"].contains(source) { return .chat }
            if let data = source.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["subagent"] != nil { return .agent }
        }
        return .unknown
    }
}
struct TaskActivity {
    var turn: String
    var started: Date
    var observed: Date
    var running: Bool
    var kind: ActivityKind = .unknown
    var session = ""
    var name = ""
    var eventDate = Date.distantPast
    var created = Date.distantPast
    var tool: LiveTool = .codex
}
struct RateMeasurement {
    var turn: String
    var date: Date
    var duration: TimeInterval
    var output: Int
    var model: String
    var rate: Double { Double(output) / duration }
    // Sparse reporters get a longer freshness interval, but never an unlimited hold.
    var lifetime: TimeInterval { min(120, max(30, duration * 3)) }
}
struct ActivitySnapshot {
    var turns: [String: TaskActivity] = [:]
    var measurements: [String: RateMeasurement] = [:]
    var readAt: Date?
    var error: String?
    var toolErrors: [LiveTool: String] = [:]
    /// Optional evaluation clock for isolated synthetic snapshots; readers leave it nil.
    var referenceDate: Date?
    func active(at now: Date) -> [TaskActivity] { turns.values.filter { $0.running && now.timeIntervalSince($0.observed) < 300 } }
    var running: [TaskActivity] { active(at: referenceDate ?? Date()) }
    var chatCount: Int { running.filter { $0.kind == .chat }.count }
    var agentCount: Int { running.filter { $0.kind == .agent }.count }
    var unknownCount: Int { running.filter { $0.kind == .unknown }.count }
    var uncertain: Int { turns.values.filter { $0.running && (referenceDate ?? Date()).timeIntervalSince($0.observed) >= 300 }.count }
    /// Latest dated lifecycle or counter evidence at or before `now`; never a read time or file mtime.
    func lastEvidence(at now: Date) -> Date? {
        (turns.values.map(\.eventDate) + measurements.values.map(\.date))
            .filter { $0 != .distantPast && $0 <= now }.max()
    }
    func freshMeasurements(at now: Date) -> [RateMeasurement] {
        active(at: now).compactMap { task in
            guard let sample = measurements[task.session], sample.turn == task.turn,
                  sample.date <= now, now.timeIntervalSince(sample.date) < sample.lifetime else { return nil }
            return sample
        }
    }
}
final class ActivityReader {
    private var sessions: [String: TaskActivity] = [:]
    private var measurements: [String: RateMeasurement] = [:]
    private var offsets: [String: UInt64] = [:]
    private var counters: [String: (output: Int, date: Date)] = [:]
    var snapshot: ActivitySnapshot {
        // Fork copies of the same turn are one activity, not extra running chats.
        var turns: [String: TaskActivity] = [:]
        for task in sessions.values {
            if let prior = turns[task.turn] {
                if prior.created < task.created { continue }
                if prior.created == task.created && prior.eventDate > task.eventDate { continue }
                if prior.eventDate == task.eventDate && (!prior.running || prior.session < task.session) { continue }
            }
            turns[task.turn] = task
        }
        return ActivitySnapshot(turns: turns, measurements: measurements, readAt: Date())
    }
    func consume(_ root: [String: Any], observed: Date, kind: ActivityKind = .unknown, session: String? = nil, name: String = "", model: String = "", created: Date = .distantPast) {
        guard root["type"] as? String == "event_msg", let p = root["payload"] as? [String: Any],
              let type = p["type"] as? String, let stamp = root["timestamp"] as? String,
              let date = EventTime.parse(stamp) else { return }
        if type == "token_count", let session, let task = sessions[session], task.running,
           let info = p["info"] as? [String: Any], let total = info["total_token_usage"] as? [String: Any],
           let output = total["output_tokens"] as? Int {
            defer {
                if counters[session] == nil || counters[session]!.output != output { counters[session] = (output, date) }
            }
            guard let previous = counters[session], date > previous.date else { return }
            if output < previous.output { measurements[session] = nil; return }
            guard output > previous.output else { return }
            let elapsed = date.timeIntervalSince(previous.date)
            guard elapsed <= 120 else { measurements[session] = nil; return }
            measurements[session] = RateMeasurement(turn: task.turn, date: date, duration: elapsed,
                output: output - previous.output, model: model)
            return
        }
        guard ["task_started", "task_complete", "turn_aborted"].contains(type),
              let turn = p["turn_id"] as? String ?? session.flatMap({ sessions[$0]?.turn }) else { return }
        let key = session ?? turn
        let previous = sessions[key]
        if let previous, previous.eventDate > date || (previous.eventDate == date && !previous.running && type == "task_started") { return }
        let turnTime = UInt64(turn.replacingOccurrences(of: "-", with: "").prefix(12), radix: 16).flatMap { value -> Date? in
            guard turn.count == 36, value > 1_500_000_000_000 else { return nil }
            return Date(timeIntervalSince1970: Double(value) / 1000)
        }
        let start = (p["started_at"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? turnTime ?? (previous?.turn == turn ? previous!.started : date)
        // Inherited turns predate the fork's own creation and are not new work in that session.
        guard start >= created.addingTimeInterval(-2) else { return }
        if previous?.turn != turn { counters[key] = nil; measurements[key] = nil }
        sessions[key] = TaskActivity(turn: turn, started: start, observed: observed, running: type == "task_started",
            kind: kind == .unknown ? (previous?.kind ?? .unknown) : kind, session: key, name: name, eventDate: date, created: created)
    }
    private func relevant(_ data: Data) -> Bool {
        ["task_started", "task_complete", "turn_aborted", "token_count"].contains { data.range(of: Data($0.utf8)) != nil }
    }
    private(set) var bootstrapPeakBuffer = 0
    /// Walk fixed-size blocks to any distance. Newline offsets carry a split
    /// line across blocks without retaining its bytes. Candidate decoding (and
    /// the forward getline reader) can still allocate one arbitrarily long line.
    private func bootstrapOffset(_ file: UnsafeMutablePointer<FILE>, size: UInt64) -> UInt64 {
        bootstrapPeakBuffer = 0
        var upper = size
        var lineEnd: UInt64?
        func lifecycle(at start: UInt64, end: UInt64) -> Bool {
            guard end > start else { return false }
            fseeko(file, off_t(start), SEEK_SET)
            var prefix = Data(count: Int(min(700, end - start)))
            let prefixLength = prefix.count
            let count = prefix.withUnsafeMutableBytes { fread($0.baseAddress, 1, prefixLength, file) }
            guard count == prefix.count,
                  ["task_started", "task_complete", "turn_aborted"].contains(where: { prefix.range(of: Data($0.utf8)) != nil }) else { return false }
            fseeko(file, off_t(start), SEEK_SET)
            var bytes = Data(count: Int(end - start))
            let length = bytes.count
            guard bytes.withUnsafeMutableBytes({ fread($0.baseAddress, 1, length, file) }) == length,
                  let root = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  root["type"] as? String == "event_msg", let payload = root["payload"] as? [String: Any],
                  let type = payload["type"] as? String else { return false }
            return ["task_started", "task_complete", "turn_aborted"].contains(type)
        }
        while upper > 0 {
            let lower = upper > 262_144 ? upper - 262_144 : 0
            let length = Int(upper - lower)
            fseeko(file, off_t(lower), SEEK_SET)
            var bytes = Data(count: length)
            guard bytes.withUnsafeMutableBytes({ fread($0.baseAddress, 1, length, file) }) == length else { return 0 }
            bootstrapPeakBuffer = max(bootstrapPeakBuffer, bytes.count)
            for index in bytes.indices.reversed() where bytes[index] == 10 {
                let newline = lower + UInt64(index)
                if let end = lineEnd, lifecycle(at: newline + 1, end: end) { return newline + 1 }
                lineEnd = newline
            }
            upper = lower
        }
        if let end = lineEnd, lifecycle(at: 0, end: end) { return 0 }
        return 0
    }
    func read(_ url: URL, modified: Date, size: UInt64, session: String? = nil, kind: ActivityKind = .unknown, name: String = "", model: String = "", created: Date = .distantPast) {
        guard let file = fopen(url.path, "r") else { return }
        defer { fclose(file) }
        let key = session ?? url.path
        var resolvedKind = kind
        if resolvedKind == .unknown {
            var header: UnsafeMutablePointer<CChar>?, capacity = 0
            let length = getline(&header, &capacity, file)
            if length > 0, length < 65_536, let header,
               let root = try? JSONSerialization.jsonObject(with: Data(bytes: header, count: length)) as? [String: Any],
               root["type"] as? String == "session_meta", let metadata = root["payload"] as? [String: Any] {
                resolvedKind = ActivityKind.classify(metadata)
            }
            free(header)
        }
        if let old = offsets[url.path], size < old { offsets[url.path] = nil; sessions[key] = nil; counters[key] = nil; measurements[key] = nil }
        let offset = offsets[url.path] ?? bootstrapOffset(file, size: size)
        fseeko(file, off_t(offset), SEEK_SET)
        var line: UnsafeMutablePointer<CChar>?, capacity = 0
        defer { free(line) }
        var end = offset
        while UInt64(ftello(file)) < size {
            let length = getline(&line, &capacity, file)
            guard length > 0, let line, line[length - 1] == 10 else { break }
            let prefix = Data(bytes: line, count: min(length, 700))
            if relevant(prefix), let root = try? JSONSerialization.jsonObject(with: Data(bytes: line, count: length)) as? [String: Any] {
                consume(root, observed: modified, kind: resolvedKind, session: key, name: name, model: model, created: created)
            }
            end = UInt64(ftello(file))
        }
        offsets[url.path] = end
        if var task = sessions[key] { task.observed = modified; task.kind = resolvedKind; task.name = name; sessions[key] = task }
    }
    func observeGrok(session: String, kind: ActivityKind, output: Int, date: Date, running: Bool, turn: String, model: String, outputDate: Date? = nil, name: String = "") {
        let previous = sessions[session]
        if previous == nil {
            counters[session] = nil
            measurements[session] = nil
        }
        sessions[session] = TaskActivity(turn: turn, started: previous?.started ?? date, observed: date, running: running,
            kind: kind, session: session, name: name.isEmpty ? (previous?.name ?? "") : name, eventDate: date, created: previous?.created ?? date, tool: .grok)
        let stamp = outputDate ?? date
        guard running, let prior = counters[session], stamp > prior.date else {
            if counters[session] == nil || counters[session]!.output != output { counters[session] = (output, stamp) }
            return
        }
        defer { if counters[session] == nil || counters[session]!.output != output { counters[session] = (output, stamp) } }
        if output < prior.output { measurements[session] = nil; return }
        guard output > prior.output else { return }
        let elapsed = stamp.timeIntervalSince(prior.date)
        guard elapsed <= 120 else { measurements[session] = nil; return }
        measurements[session] = RateMeasurement(turn: turn, date: stamp, duration: elapsed, output: output - prior.output, model: model)
    }
}
