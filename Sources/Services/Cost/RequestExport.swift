import Foundation

enum RequestExport {
    static func quote(_ text: String) -> String {
        let prefix = ["=", "+", "-", "@", "\t", "\r"].contains(where: text.hasPrefix) ? "'" : ""
        return "\"" + prefix + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    /// Stream to a sibling temporary file so failed exports never replace the user's previous file.
    static func write(archive: RequestArchive, destination: URL, query: UsageQuery, catalog: [String: TaskInfo], effort: String, now: Date = Date()) throws -> Int {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".token-bar-export-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let file = try FileHandle(forWritingTo: temporary); defer { try? file.close() }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let header = "timestamp,record_id,task,turn,provider,model,reasoning_level,input,cached_input,cache_write_input,output,reasoning_subset,recorded_fields,request_input_tokens,granularity,requested_service,observed_service,service_evidence,account_attribution,cache_write_5m_input,cache_write_1h_input,thinking_subset,observed_speed,model_calls,provider_cost_usd_ticks,provider_cost_partial\n"
        try file.write(contentsOf: Data(header.utf8))
        var count = 0
        let bounds = query.timeBounds(now: now)
        try archive.forEach(start: bounds.lower, end: bounds.upper) { entry in
            guard query.includes(entry, catalog: catalog, now: now), effort == "All levels" || (entry.effort ?? "Unknown") == effort else { return }
            var values = [iso.string(from: entry.date), entry.recordID ?? "", entry.session, entry.turnID ?? "", entry.provider ?? "", entry.model, entry.effort ?? ""]
            let tokens = entry.tokens
            values += [entry.hasField("input_tokens") ? String(tokens.input) : "", entry.hasField("cached_input_tokens") ? String(tokens.cached) : "", tokens.cacheWrite.map(String.init) ?? "", entry.hasField("output_tokens") ? String(tokens.output) : "", entry.hasField("reasoning_output_tokens") ? String(tokens.reasoning) : ""]
            values += [entry.tokenFields?.joined(separator: ";") ?? "", entry.requestInputTokens.map(String.init) ?? "", entry.bucket == "revision" ? "message_increment" : entry.requestInputTokens == nil ? "aggregate_delta" : "single_request", entry.requestedService ?? "", entry.observedService ?? "", entry.serviceEvidence ?? "", UsageMetadata.accountAttribution(entry.account)]
            values += [tokens.cacheWrite5m.map(String.init) ?? "", tokens.cacheWrite1h.map(String.init) ?? "", tokens.thinking.map(String.init) ?? "", entry.observedSpeed ?? "", entry.modelCalls.map(String.init) ?? "", entry.costUsdTicks.map(String.init) ?? "", entry.costIsPartial.map(String.init) ?? ""]
            try file.write(contentsOf: Data((values.map(quote).joined(separator: ",") + "\n").utf8)); count += 1
        }
        try file.synchronize(); try file.close()
        if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary) }
        else { try FileManager.default.moveItem(at: temporary, to: destination) }
        return count
    }
}
