import Foundation

/// Independent tail reader: no history import or prompt analysis on the live queue.
/// Rates use logged counter increments and timestamps, never characters or file size.
final class ClaudeActivityReader {
    private var offsets: [URL: UInt64] = [:]
    private var identities: [URL: (dev_t, ino_t)] = [:]
    private var tasks: [String: TaskActivity] = [:]
    private var samples: [String: RateMeasurement] = [:]
    private var counters: [String: (Int, Date)] = [:]
    private var owners: [String: String] = [:]
    private var lastReport: [String: Date] = [:]
    private var failures = Set<URL>()
    func consume(_ root: [String: Any], source: String) {
        guard let date = EventTime.parse(root["timestamp"]) else { return }
        let key = "claude:" + source
        let type = root["type"] as? String
        if let task = tasks[key], date < task.eventDate { return }
        if type == "user", root["isMeta"] as? Bool != true, let message = root["message"] as? [String: Any] {
            // Tool results continue the same turn. Only a user message starts one.
            let content = message["content"] as? [[String: Any]]
            if content?.contains(where: { $0["type"] as? String == "tool_result" }) == true { return }
            let turn = root["uuid"] as? String ?? date.description
            tasks[key] = TaskActivity(turn: "claude:" + turn, started: date, observed: date, running: true,
                kind: root["isSidechain"] as? Bool == true ? .agent : .chat, session: key,
                name: "Claude task", eventDate: date, created: date, tool: .claude)
            samples[key] = nil; lastReport[key] = date
            return
        }
        if (type == "system" && root["subtype"] as? String == "turn_duration") || type == "result" {
            tasks[key]?.running = false; tasks[key]?.eventDate = date; samples[key] = nil
            return
        }
        guard let turn = ClaudeCodeUsage.turn(from: root) else { return }
        if let owner = owners[turn.messageID], owner != key { return }
        owners[turn.messageID] = key
        let prior = counters[turn.messageID]
        if tasks[key] == nil {
            tasks[key] = TaskActivity(turn: "claude:" + turn.messageID, started: date, observed: date, running: true,
                kind: turn.isSidechain ? .agent : .chat, session: key, name: "Claude task", eventDate: date, created: date, tool: .claude)
        }
        // Repeated unchanged counters are not a new measurement or a freshness heartbeat.
        if prior == nil || turn.tokens.output > prior!.0 {
            let start = prior?.1 ?? lastReport[key]
            if let start, date > start, date.timeIntervalSince(start) <= 120 {
                let output = turn.tokens.output - (prior?.0 ?? 0)
                if output > 0 {
                    samples[key] = RateMeasurement(turn: tasks[key]!.turn, date: date,
                        duration: date.timeIntervalSince(start), output: output, model: turn.model)
                }
            }
            counters[turn.messageID] = (turn.tokens.output, date); lastReport[key] = date
            tasks[key]?.observed = date
        }
        tasks[key]?.eventDate = date
        let message = root["message"] as? [String: Any]
        if message?["stop_reason"] as? String == "end_turn" {
            tasks[key]?.running = false; samples[key] = nil
        }
    }
    func read(_ incomingURL: URL) {
        let url = incomingURL.resolvingSymlinksInPath().standardizedFileURL
        do {
            guard let file = fopen(url.path, "r") else { throw CocoaError(.fileReadNoPermission) }
            defer { fclose(file) }
            var metadata = stat()
            guard fstat(fileno(file), &metadata) == 0, metadata.st_size >= 0 else { throw CocoaError(.fileReadUnknown) }
            let size = UInt64(metadata.st_size)
            var offset = offsets[url] ?? 0
            let replaced = identities[url].map { $0.0 != metadata.st_dev || $0.1 != metadata.st_ino } ?? false
            identities[url] = (metadata.st_dev, metadata.st_ino)
            if size < offset || replaced {
                offset = 0; tasks["claude:" + url.path] = nil; samples["claude:" + url.path] = nil; lastReport["claude:" + url.path] = nil
                // Message identities remain remembered: truncation must not replay old output.
            }
            fseeko(file, off_t(offset), SEEK_SET)
            var line: UnsafeMutablePointer<CChar>?, capacity = 0
            defer { free(line) }
            while UInt64(ftello(file)) < UInt64(size) {
                let length = getline(&line, &capacity, file)
                guard length > 0, let line, line[length - 1] == 10 else { break }
                let data = Data(bytes: line, count: length)
                if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { consume(root, source: url.path) }
                offset = UInt64(ftello(file))
            }
            if ferror(file) != 0 { throw CocoaError(.fileReadUnknown) }
            offsets[url] = offset; failures.remove(url)
        } catch { failures.insert(url) }
    }
    func snapshot(now: Date = Date()) -> ActivitySnapshot {
        // Retain only the recent rate baselines; log cursors still prevent old data replay.
        let old = counters.filter { now.timeIntervalSince($0.value.1) > 600 }.map(\.key)
        for id in old { counters[id] = nil; owners[id] = nil }

        var unique: [String: TaskActivity] = [:]
        for task in tasks.values {
            if let prior = unique[task.turn] {
                if prior.eventDate > task.eventDate { continue }
                if prior.eventDate == task.eventDate && (!prior.running || prior.session < task.session) { continue }
            }
            unique[task.turn] = task
        }
        return ActivitySnapshot(turns: unique, measurements: samples, readAt: now, error: failures.isEmpty ? nil : "Some Claude activity logs could not be read; live activity may be incomplete.")
    }
}
