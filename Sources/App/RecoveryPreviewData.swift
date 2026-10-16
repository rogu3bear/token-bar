import Foundation

/// Persisted counterpart to CostPreview's display-only page states. The ordinary
/// scanner creates the gap, admissions and checkpoints before UsageModel loads.
enum RecoveryPreviewData {
    static let total = 363_000
    static let unpriced = 330_000

    static func seed(root: URL) throws {
        let file = root.appendingPathComponent("sessions/recovery.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let date = PreviewFixture.date.addingTimeInterval(-300)
        func line(_ value: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) + Data([10])
        }
        func meta(_ session: String) throws -> Data {
            try line(["type": "session_meta", "payload": ["id": session, "cwd": "/synthetic/recovery",
                "originator": "codex_cli_rs", "model_provider": "openai"]])
        }
        func record(_ turn: String, _ total: Int, _ seconds: TimeInterval = 0,
                    model: String = "synthetic-unpriced-model", last: Int = 100_000) throws -> Data {
            try line(["type": "turn_context", "payload": ["turn_id": turn, "model": model]]) +
            line(["timestamp": date.addingTimeInterval(seconds).ISO8601Format(), "type": "event_msg",
                "payload": ["type": "token_count", "info": [
                    "total_token_usage": ["input_tokens": total, "cached_input_tokens": 0,
                        "cache_write_input_tokens": 0, "output_tokens": total / 10, "reasoning_output_tokens": 0],
                    "last_token_usage": ["input_tokens": last, "cached_input_tokens": 0,
                        "cache_write_input_tokens": 0, "output_tokens": last / 10, "reasoning_output_tokens": 0]]]])
        }
        let prefix = try meta("recovery-session")
        try (prefix + record("A", 100_000) + record("B", 200_000)).write(to: file)
        let scanner = UsageScanner(home: root, stateURL: root.appendingPathComponent("CodexTokenBar/ledger.json"))
        scanner.readAccount = false
        _ = scanner.scan(historical: true)
        // Reproduce the tested overlap boundary: prior admissions survive,
        // ambiguous overlap is withheld, then independently supported work resumes.
        try (prefix + record("A", 100_000) + record("unseen-older", 150_000, -1) +
             record("overlap", 250_000, 1)).write(to: file, options: .atomic)
        _ = scanner.scan(historical: true)
        let append = try FileHandle(forWritingTo: file)
        try append.seekToEnd()
        try append.write(contentsOf: record("independent", 300_000, 2))
        try append.close()
        let priced = root.appendingPathComponent("sessions/priced.jsonl")
        try (meta("priced-session") + record("priced", 30_000, 3, model: "gpt-5.6-sol", last: 30_000)).write(to: priced)
        _ = scanner.scan(historical: true)
        scanner.ledger.costMetadataVersion = 2
        scanner.markMetadataDirty()
        try scanner.saveIfNeeded(force: true)
        let saved = try UsageScanner.loadLedger(from: scanner.stateURL)
        precondition(saved.entries.reduce(0) { $0 + $1.tokens.total } == total)
        precondition(!scanner.currentSnapshot().readHealth.failed && scanner.currentSnapshot().readHealth.continuityCount > 0)
        precondition(saved.lastSuccessfulRead != nil)
    }

    @MainActor static func bind(_ model: UsageModel, root: URL) throws {
        model.appearance.websitePreset()
        model.scanner.readAccount = false
        model.period = 2
        model.costBasis = .reference
        model.rebuild()
        try PreviewFixture.settle("persisted recovery report") { !model.filtering }
        let saved = try UsageScanner.loadLedger(from: model.scanner.stateURL)
        precondition(saved.entries == model.snapshot.entries)
        precondition(model.report.totals.total == total && model.snapshot.readHealth.continuityCount > 0)
        precondition(model.costReport.unpricedTokens == unpriced)
        precondition(!model.snapshot.readHealth.failed && model.snapshot.readHealth.lastSuccessfulRead != nil)
        precondition(QuotaGuardNotifications.constructionCount == 0)
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--sample-recovery-receipt"), arguments.indices.contains(index + 1) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let receipt: [String: Any] = ["root": root.path, "source": root.appendingPathComponent("sessions/recovery.jsonl").path,
            "ledger": model.scanner.stateURL.path, "processedTokens": model.report.totals.total,
            "expectedUnpricedTokens": unpriced, "coverageWarnings": model.snapshot.readHealth.continuityCount,
            "currentReadFailed": model.snapshot.readHealth.failed, "notificationAdapters": QuotaGuardNotifications.constructionCount,
            "startingEvidence": "Scanner-created persisted ledger and source diagnostics loaded by UsageModel; no display snapshot assignment"]
        let destination = URL(fileURLWithPath: arguments[index + 1])
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: destination, options: .atomic)
        print("PASS: persisted recovery fixture loads \(total) processed tokens and historical gaps with no current failure")
    }
}
