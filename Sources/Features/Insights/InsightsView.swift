import SwiftUI

struct InsightsView: View {
    @Environment(\.appAccent) private var accent
    @Bindable var model: InsightsModel
    var home: URL
    @Bindable var usage: UsageModel
    @Bindable var trends: UsageInsightsModel
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: PageStyle.section) {
                PageHeader("Insights", subtitle: "Changes and interpretation limits in local evidence, updated quietly in the background.")
                if let error = usage.snapshot.error { ErrorNotice(message: error) }
                if trends.sourceUnavailable {
                    ErrorNotice(message: trends.hasResult ? "Usage refresh unavailable. Previous trends remain visible and may be stale." : "Usage trends unavailable. No successful usage result is available.")
                    if trends.hasResult, let date = usage.lastSuccessfulUsageRead {
                        Text("Last successful usage read " + date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if trends.hasResult {
                    UsageInsightsView(summary: trends.summary, monitor: usage.live,
                                      notices: usage.provenanceNotices, integrity: usage.snapshot.integrity)
                } else if !trends.sourceUnavailable {
                    Text("Usage patterns will appear when local history is ready.").foregroundStyle(.secondary)
                }
                Divider().padding(.vertical, 8)
                PromptInsightsSection(state: model.state)
            }.padding(PageStyle.gutter).background(ScrollIndicatorSuppression())
        }.task {
            guard usage.referenceDate == nil else { return } // Isolated fixtures publish explicitly.
            // Let navigation settle. Cancellation prevents work when the page is
            // left before this delay; work already running finishes off-main.
            do {
                try await Task.sleep(for: .seconds(1))
                while !Task.isCancelled {
                    if !usage.busy && !usage.filtering && usage.progress == nil {
                        trends.refresh(entries: usage.snapshot.entries, catalog: usage.catalog,
                                       sourceAvailable: usage.snapshot.error == nil || !usage.snapshot.entries.isEmpty)
                        if !trends.busy { model.refresh(home: home) }
                    }
                    try await Task.sleep(for: .seconds(trends.busy ? 1 : 15))
                }
            } catch { /* Leaving the destination cancels only its scheduling task. */ }
        }
    }
}
