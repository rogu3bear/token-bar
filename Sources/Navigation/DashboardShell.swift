import SwiftUI

final class DashboardSelection: ObservableObject {
    @Published var destination: Destination
    init(_ destination: Destination = .history) { self.destination = destination }
}

/// The persistent dashboard shell. It holds the selection and the chrome above
/// the changing region, and deliberately does not observe `UsageModel`: model
/// churn must redraw the destination, not the navigation.
struct DashboardRoot: View {
    let model: UsageModel
    @StateObject private var selection: DashboardSelection
    init(model: UsageModel, initialDestination: Destination = .history, selection: DashboardSelection? = nil) {
        self.model = model
        _selection = StateObject(wrappedValue: selection ?? DashboardSelection(initialDestination))
    }
    var body: some View {
        VStack(spacing: 0) {
            if Destination.capsule.contains(selection.destination) {
                DashboardNavigation(selection: $selection.destination)
                    .padding(.horizontal, PageStyle.gutter).padding(.vertical, 8)
            }
            DestinationHost(destination: selection.destination, model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if selection.destination != .now { ImportStatusView(model: model) }
        }.padding(8).frame(minWidth: ReportWindowGeometry.minWidth, minHeight: ReportWindowGeometry.minHeight)

    }
}

/// The one region replaced by selection. Everything above it keeps its
/// identity, so changing destination never rebuilds the shell.
struct DestinationHost: View {
    let destination: Destination
    @Bindable var model: UsageModel
    var body: some View {
        Group {
        switch destination {
        case .now: LiveOverview(meter: model.tachometer, model: model, monitor: model.live)
        case .history: HistoryView(model: model)
        case .cost: CostView(model: model)
        case .accounts: AccountsView(model: model, monitor: model.live, signIns: model.signIns)
        case .insights: InsightsView(model: model.insights, home: model.scanner.home, usage: model, trends: model.usageInsights)
        case .menuBar: MenuBarSettingsView(allowsSystemSettings: model.allowsSystemSettings, preferences: model.menuBarPreferences, appearance: model.appearance, meter: model.tachometer, claudeMeter: model.claudeMeter, grokMeter: model.grokMeter, monitor: model.live, claudeQuota: model.claudeQuota, grokQuota: model.grokQuota, claudeConnection: model.claudeConnection, quotaGuard: model.quotaGuard, updateCheck: model.updateCheck)
        case .appearance: DestinationHost(destination: .menuBar, model: model)
        }
        }.environment(\.evaluationDate, model.referenceDate)
    }
}
