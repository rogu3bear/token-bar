import SwiftUI

/// Presentation only: the original diagnostic string is never shortened or rewritten.
struct NoticeContent {
    let message: String
    let summary: String
    let needsDetails: Bool
    let continuityCount: Int
    let pageCount: Int

    init(_ message: String) {
        self.message = message
        let count = message.count
        pageCount = max(1, (count + Self.pageSize - 1) / Self.pageSize)
        needsDetails = count > 600 || message.split(separator: "\n", maxSplits: 6, omittingEmptySubsequences: false).count > 6
        // Count diagnostic occurrences, not unique sources. Live and historical
        // coverage may legitimately carry separate warnings for the same source.
        let markers = [
            "Source was replaced by a different session; prior totals retained.",
            "Source continuity is incomplete across a session change; prior totals retained.",
            "Source continuity is incomplete; retained prior totals and admitted only independently supported requests.",
            "Multiple legacy cursor aliases required reconciliation; prior totals retained and coverage remains incomplete."
        ]
        continuityCount = needsDetails ? markers.reduce(0) { $0 + message.components(separatedBy: $1).count - 1 } : 0
        if continuityCount > 0 {
            summary = "Source diagnostics include \(continuityCount.formatted()) continuity warnings. Available usage is retained; coverage remains incomplete. View details for all reported issues."
        } else if needsDetails {
            summary = String(message.prefix(240)) + "…"
        } else { summary = message }
    }

    /// Only this slice is handed to SwiftUI Text. Paging keeps even one enormous
    /// line selectable without constructing its entire text layout.
    static let pageSize = 3000
    func page(_ index: Int) -> String {
        guard index >= 0, index < pageCount else { return "" }
        let start = message.index(message.startIndex, offsetBy: index * Self.pageSize)
        let end = message.index(start, offsetBy: Self.pageSize, limitedBy: message.endIndex) ?? message.endIndex
        return String(message[start..<end])
    }
}

struct NoticeDetails: View {
    let content: NoticeContent
    @State private var page = 0
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Diagnostic details").font(.title2)
            Text("Select text to copy. Use Previous and Next to read all details.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                Text(content.page(page)).font(.callout.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(page)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Button("Previous") { page -= 1 }.disabled(page == 0)
                Text("Part \(page + 1) of \(content.pageCount)").monospacedDigit()
                Button("Next") { page += 1 }.disabled(page + 1 >= content.pageCount)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 580, height: 440).appCanvas()
            .onExitCommand { dismiss() }
    }
}

/// One bounded presentation for failures and degraded evidence. Dismissal only
/// hides this notice; neither it nor opening details mutates source state.
struct StatusNotice: View {
    var message: String
    var severity: NoticeSeverity
    var dismissible = true
    @Environment(\.noticeDismissals) private var notices
    @State private var appeared = false
    @State private var showsDetails = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let content = NoticeContent(message)
        let key = NoticeDismissals.key([severity.rawValue, message])
        VStack(spacing: 0) {
            if appeared && !message.isEmpty && !notices.contains(key) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: severity.symbol).foregroundStyle(severity.color).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 8) {
                        // Native selectable text supplies its own accessibility
                        // label. Overriding it can recurse in macOS accessibility.
                        Text(severity.rawValue + ": " + content.summary).font(.callout).textSelection(.enabled)
                            .lineLimit(content.needsDetails ? 4 : nil)
                        if content.needsDetails {
                            Button("View diagnostic details") { showsDetails = true }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if dismissible {
                        DismissNoticeButton(label: "Dismiss " + severity.rawValue.lowercased()) { notices.dismiss(key) }
                    }
                }.moduleSurface(padding: 12, warning: true)
                    .transition(.opacity)
            }
        }.animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: appeared)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: notices.contains(key))
            .onAppear { appeared = true }
            .sheet(isPresented: $showsDetails) { NoticeDetails(content: content).id(message) }
    }
}

struct ErrorNotice: View {
    var message: String
    var body: some View { StatusNotice(message: message, severity: .error) }
}

/// Independent evidence axes. A value of zero never selects an availability state.
struct ReadPresentation: Equatable {
    enum Availability { case available, unavailable }
    enum Coverage { case complete, partial, unknown }
    enum Freshness { case current, loading, refreshing, stale, waiting }
    let availability: Availability
    let coverage: Coverage
    let freshness: Freshness
    let failed: Bool

    init(hasResult: Bool, refreshing: Bool = false, failed: Bool = false, partial: Bool = false) {
        availability = hasResult ? .available : .unavailable
        coverage = hasResult ? (partial ? .partial : .complete) : .unknown
        freshness = refreshing ? (hasResult ? .refreshing : .loading) : failed && hasResult ? .stale : hasResult ? .current : .waiting
        self.failed = failed
    }
    init(snapshot: Snapshot, refreshing: Bool = false, additionalPartial: Bool = false) {
        self.init(hasResult: snapshot.hasUsageResult, refreshing: refreshing,
                  failed: snapshot.readHealth.failed,
                  partial: snapshot.readHealth.partial || additionalPartial || snapshot.integrity.map { !$0.isClean } == true)
    }
    var caption: String {
        let base: String
        switch freshness {
        case .loading: base = "Loading…"
        case .refreshing: base = "Updating · previous results remain visible"
        case .stale: base = "Refresh failed · previous results may be stale"
        case .current: base = "Read completed"
        case .waiting: base = failed ? "Unavailable · no successful reading" : "Awaiting a reading"
        }
        return base + (coverage == .partial ? " · coverage incomplete" : "")
    }
    var needsAttention: Bool { failed || coverage == .partial }
}

/// One restrained status row for reports and sampled results; diagnostics stay intact below it.
struct ReadStatusView: View {
    var state: ReadPresentation
    var date: Date? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(state.caption, systemImage: state.needsAttention ? "exclamationmark.triangle" : "clock")
                .foregroundStyle(.secondary)
            if let date { ReadAgeCaption(date: date, prefix: "Last successful read") }
        }.font(.caption).foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
    }
}

/// Report toolbar freshness; coverage is explained once beside the summary.
struct ReportFreshness: View {
    var state: ReadPresentation
    var date: Date?
    private var caption: String {
        switch state.freshness {
        case .loading: return "Loading history…"
        case .refreshing: return "Updating · previous results shown"
        case .stale: return "Refresh failed · previous history shown"
        case .waiting: return state.failed ? "History unavailable" : "Waiting for history"
        case .current:
            return date.map { "Updated " + $0.formatted(date: .omitted, time: .shortened) } ?? "History loaded"
        }
    }
    var body: some View {
        Group {
            if state.freshness == .current, let date {
                ReadAgeCaption(date: date, prefix: "Updated", includesClock: false)
            } else { Text(caption) }
        }.font(.caption).foregroundStyle(.secondary)
            .help(date.map { "Last successful history read " + $0.formatted(date: .abbreviated, time: .shortened) } ?? caption)
    }
}
