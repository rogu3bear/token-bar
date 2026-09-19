import Foundation
import Observation

/// Process-owned ingestion state. Report queries and live rate ticks do not
/// invalidate consumers that only read import status or saved usage.
@Observable final class UsageStore {
    let scanner: UsageScanner
    var snapshot = Snapshot() {
        didSet {
            let changed = oldValue.contentID != nil && snapshot.contentID != nil
                ? oldValue.contentID != snapshot.contentID : oldValue.entries != snapshot.entries
            if changed { revision &+= 1 }
            updateCompactUsage(now: referenceDate ?? Date())
        }
    }
    @ObservationIgnored private(set) var revision: UInt64 = 0
    @ObservationIgnored private var compactCache = CompactUsageCache()
    @ObservationIgnored private let referenceDate: Date?
    private(set) var compactUsage = CompactUsage()
    var lastSuccessfulUsageRead: Date?
    var busy = false
    var retainedRequests: Int?
    var costRecoveryMessage: String?
    var progress: ImportProgress?
    var message: String?
    init(scanner: UsageScanner, referenceDate: Date? = nil) {
        self.scanner = scanner
        self.referenceDate = referenceDate
    }
    func updateCompactUsage(now: Date) {
        if let value = compactCache.update(entries: snapshot.entries, revision: revision, now: referenceDate ?? now) {
            compactUsage = value
        }
    }
}

@Observable final class ReportState {
    @ObservationIgnored var queryChanged: (() -> Void)?
    @ObservationIgnored private(set) var catalogRevision: UInt64 = 0
    var period = 0 { didSet { if oldValue != period { queryChanged?() } } }
    var toolFilter = "All tools" { didSet { if oldValue != toolFilter { queryChanged?() } } }
    var modelFilter = "All models" { didSet { if oldValue != modelFilter { queryChanged?() } } }
    var accountFilter = "All accounts" { didSet { if oldValue != accountFilter { queryChanged?() } } }
    var search = "" { didSet { if oldValue != search { queryChanged?() } } }
    var startDate = Calendar.current.date(byAdding: .day, value: -29, to: Date())! { didSet { if oldValue != startDate { queryChanged?() } } }
    var endDate = Date() { didSet { if oldValue != endDate { queryChanged?() } } }
    var costEffort = "All levels" { didSet { if oldValue != costEffort { queryChanged?() } } }
    var costService = CostService.standard { didSet { if oldValue != costService { queryChanged?() } } }
    var costBasis = CostPriceBasis.historical { didSet { if oldValue != costBasis { queryChanged?() } } }
    var report = UsageReport()
    var costReport = CostReport()
    var filtering = false
    var exportingRequests = false
    var availableTools: [String] = []
    var availableModels: [String] = []
    var availableAccounts: [Account] = []
    var availableEfforts: [String] = []
    var catalog: [String: TaskInfo] = [:] { didSet { if oldValue != catalog { catalogRevision &+= 1 } } }
}

/// In-flight report selection. The dashboard banner and the History/Cost filter
/// caption are the same claim; export is held only where export exists.
enum ReportUpdateCopy {
    static let title = "Updating your report…"
    static let waiting = "Showing the previous report until the new one is ready."
    static let exportHold = "Export is unavailable while updating."
    static var filterCaption: String { "Updating your report. " + waiting + " " + exportHold }
}

/// One app-owned tick. Views read this only where wall-clock labels need it;
/// isolated previews continue to supply their explicit evaluation date.
@Observable final class PresentationClock {
    var now: Date
    init(now: Date = Date()) { self.now = now }
}
