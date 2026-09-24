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

    /// Reports navigation. Live, Insights and Settings stay hostable without extra destinations.
    static var capsule: [Destination] { [.history, .cost, .accounts] }
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

/// Compact section tabs keep report navigation distinct from chart measure pickers.
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
        HStack(spacing: 16) {
            ForEach(destinations) { destination in
                Button {
                    selection = destination
                    focused = destination
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: destination.icon)
                            .font(.system(size: 13, weight: selection == destination ? .semibold : .medium))
                        Text(destination.title)
                            .font(.system(size: 14, weight: selection == destination ? .semibold : .medium))
                    }
                    .foregroundStyle(selection == destination ? .primary : .secondary)
                    .padding(.horizontal, 8).frame(minHeight: 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressFeedbackStyle(cornerRadius: 6))
                .focused($focused, equals: destination)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(focused == destination ? Color.primary.opacity(0.6) : .clear, lineWidth: 2))
                .help("Open " + destination.title)
                .overlay(alignment: .bottom) {
                    if selection == destination {
                        Capsule().fill(.primary).frame(height: 2)
                            .matchedGeometryEffect(id: "selection", in: indicator)
                    }
                }
                .accessibilityAddTraits(selection == destination ? .isSelected : [])
                .onKeyPress(.leftArrow) { move(from: destination, by: -1); return .handled }
                .onKeyPress(.rightArrow) { move(from: destination, by: 1); return .handled }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 4)
        .overlay(alignment: .bottom) { Rectangle().fill(.primary.opacity(0.10)).frame(height: 1) }
        .animation(InteractionMotion.selection(reduceMotion), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reports navigation")
    }
}
