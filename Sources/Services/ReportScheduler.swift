import Foundation

/// Owns report work, coalescing and publication. Called on the main thread;
/// immutable requests are calculated on its single utility queue.
final class ReportScheduler {
    private struct Request {
        var source: [Entry]
        var inputs: ReportRevisionInputs
        var catalog: [String: TaskInfo]
        var now: Date
        var sourceID: UUID?
        var archiveURL: URL
        var failure: (String) -> Void
        var selectionGeneration: UInt64
    }
    private let state: ReportState
    private let engine: ReportEngine
    private let queue = DispatchQueue(label: "local.codex-token-bar.report", qos: .utility, autoreleaseFrequency: .workItem)
    private var completed: ReportRevisionInputs?
    private var validity: ReportValidity?
    private var inFlight: Request?
    private var pending: Request?
    private var selection: ReportRevisionInputs?
    private var selectionGeneration: UInt64 = 0
    private(set) var publicationCount = 0
    var published: ((UsageReport) -> Void)?
    init(state: ReportState, storageURL: URL) {
        self.state = state
        engine = ReportEngine(storageURL: storageURL)
    }
    func request(source: [Entry], inputs: ReportRevisionInputs, catalog: [String: TaskInfo],
                 now: Date, sourceID: UUID?, archiveURL: URL, failure: @escaping (String) -> Void) {
        if let selection, !inputs.hasSameSelection(as: selection) { selectionGeneration += 1 }
        selection = inputs
        let request = Request(source: source, inputs: inputs, catalog: catalog, now: now,
                              sourceID: sourceID, archiveURL: archiveURL, failure: failure,
                              selectionGeneration: selectionGeneration)
        if let inFlight {
            pending = inputs == inFlight.inputs && selectionGeneration == inFlight.selectionGeneration &&
                now == inFlight.now ? nil : request
            return
        }
        if inputs == completed, validity?.contains(now) == true { return }
        start(request)
    }
    private func start(_ request: Request) {
        state.filtering = true
        inFlight = request
        queue.async {
            let (report, cost) = self.engine.build(source: request.source, inputs: request.inputs,
                catalog: request.catalog, now: request.now, sourceID: request.sourceID) { selected in
                    guard let archive = try? RequestArchive(url: request.archiveURL, readOnly: true) else { return nil }
                    return try? TimelineDetail.expand(selected, archive: archive)
                }
            let validity = self.engine.validity
            let error = self.engine.storageError
            DispatchQueue.main.async {
                // New source data may queue behind a useful completed report.
                // A changed selection invalidates it, including an away/back
                // transition that returns to identical selection values.
                if request.selectionGeneration == self.selectionGeneration {
                    self.state.report = report
                    self.state.costReport = cost
                    self.completed = request.inputs
                    self.validity = validity
                    self.publicationCount += 1
                    if let error { request.failure(error) }
                    self.published?(report)
                }
                self.inFlight = nil
                if let next = self.pending {
                    self.pending = nil
                    self.start(next)
                } else { self.state.filtering = false }
            }
        }
    }
}

private extension ReportRevisionInputs {
    func hasSameSelection(as other: Self) -> Bool {
        query == other.query && effort == other.effort && service == other.service && basis == other.basis
    }
}
