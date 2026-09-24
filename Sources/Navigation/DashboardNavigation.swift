import SwiftUI

/// The dashboard's primary destinations, as values rather than positions.
/// A destination declares what it needs; the shell never infers a data
/// requirement from an index.
enum Destination: String, CaseIterable, Identifiable, Hashable {
    case now, history, cost, accounts, insights, menuBar, appearance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .now: return "Now"
        case .history: return "History"
        case .cost: return "Cost"
        case .accounts: return "Allowances"
        case .insights: return "Insights"
        case .menuBar: return "Menu bar"
        case .appearance: return "Appearance"
        }
    }
    
    var icon: String {
        switch self {
        case .now: return "gauge.with.dots.needle.bottom.100percent"
        case .history: return "chart.line.uptrend.xyaxis"
        case .cost: return "dollarsign.circle"
        case .accounts: return "person.crop.circle"
        case .insights: return "lightbulb"
        case .menuBar: return "menubar.rectangle"
        case .appearance: return "paintpalette"
        }
    }

    /// Destinations that render filtered reports and therefore need the
    /// expensive detailed rebuild while they are visible.
    var requiresDetailedReporting: Bool {
        self == .history || self == .cost
    }

    /// Persistent dashboard tabs. Insights, Menu bar and Appearance stay hostable, not capsule members.
    static var capsule: [Destination] { [.now, .history, .cost, .accounts] }
    static var settings: [Destination] { [.menuBar, .appearance] }
}

extension PageHeader {
    init(_ destination: Destination, subtitle: String? = nil, @ViewBuilder actions: @escaping () -> Actions) {
        self.init(destination.title, subtitle: subtitle, actions: actions)
    }
}

extension PageHeader where Actions == EmptyView {
    init(_ destination: Destination, subtitle: String? = nil) {
        self.init(destination.title, subtitle: subtitle)
    }
}

/// A shared selection capsule moves between destinations; page content stays still.
struct DashboardNavigation: View {
    @Binding var selection: Destination
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var indicator
    @FocusState private var focused: Destination?
    private let destinations = Destination.capsule

    private func move(from destination: Destination, by offset: Int) {
        guard let index = destinations.firstIndex(of: destination) else { return }
        let next = destinations[min(destinations.count - 1, max(0, index + offset))]
        selection = next
        focused = next
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(destinations) { destination in
                Button {
                    selection = destination
                    focused = destination
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: destination.icon)
                            .font(.system(size: 11, weight: selection == destination ? .semibold : .medium))
                        Text(destination.title)
                            .font(.system(size: 12, weight: selection == destination ? .semibold : .medium))
                    }
                    .foregroundStyle(selection == destination ? .primary : .secondary)
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .focused($focused, equals: destination)
                .overlay(Capsule().stroke(focused == destination ? Color.primary.opacity(0.6) : .clear, lineWidth: 2))
                .help("Open " + destination.title)
                .background {
                    if selection == destination {
                        Capsule().fill(.primary.opacity(0.12))
                            .matchedGeometryEffect(id: "selection", in: indicator)
                    }
                }
                .accessibilityAddTraits(selection == destination ? .isSelected : [])
                .onKeyPress(.leftArrow) { move(from: destination, by: -1); return .handled }
                .onKeyPress(.rightArrow) { move(from: destination, by: 1); return .handled }
            }
        }
        .padding(3)
        .frame(maxWidth: 840)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dashboard navigation")
    }
}
