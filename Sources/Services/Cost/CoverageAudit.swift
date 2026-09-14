import Foundation

/// Reads available sources through the production scanner, writing only into a disposable profile.
/// No current account credentials, installed ledger, prompt text or source logs are changed.
enum CoverageAudit {
    static func run(home: URL, destination: URL) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TokenBar-coverage-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        var coverage = CostCoverage()
        var scannerIntegrity: IntegrityReport?
        let result: Snapshot = {
            // Audit every tool that is actually installed, so the report shows
            // real coverage per harness rather than Codex coverage alone.
            let scanner = UsageScanner(home: home, stateURL: root.appendingPathComponent("ledger.json"),
                                       retainRequests: false,
                                       grokHome: HarnessDiscovery.grok(),
                                       claudeHome: HarnessDiscovery.claudeCode(),
                                       openCodeHome: HarnessDiscovery.openCode())
            scanner.rebuilding = true; scanner.readAccount = false
            scanner.onAdmitted = { coverage.add($0) }
            let snapshot = scanner.scan(historical: true)
            scannerIntegrity = scanner.ledger.integrity
            return snapshot
        }()
        var object = try JSONSerialization.jsonObject(with: coverage.json()) as! [String: Any]
        object["filesRead"] = result.files; object["observedAt"] = ISO8601DateFormatter().string(from: Date())
        object["sourceScope"] = "Available local sessions and archived sessions; not all-account coverage"
        object["error"] = result.error ?? NSNull()
        // Records held back are part of the honest answer, not a footnote.
        object["heldBack"] = scannerIntegrity?.quarantined ?? [:]
        object["repaired"] = scannerIntegrity?.repaired ?? [:]
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        if let error = result.error { throw RequestArchive.failure("Coverage is partial: " + error) }
    }
}
