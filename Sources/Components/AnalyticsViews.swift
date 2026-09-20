import SwiftUI
import Charts

/// Callers choose a stable presentation; live option counts never replace the control.
struct ChoiceRow<Value: Hashable>: View {
    var title: String
    @Binding var selection: Value
    var choices: [(Value, String)]
    var segmented = false
    private var picker: some View {
        Picker(title, selection: $selection) {
            ForEach(choices, id: \.0) { value, label in
                Text(label).tag(value)
            }
        }
    }
    var body: some View {
        if segmented {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                picker.pickerStyle(.segmented).labelsHidden()
            }
        } else {
            picker.pickerStyle(.menu).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 480, alignment: .leading)
        }
    }
}

struct ChoiceFlow: Layout {
    var spacing: CGFloat
    private func positions(_ views: Subviews, width: CGFloat) -> (points: [CGPoint], height: CGFloat) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        var points: [CGPoint] = []
        for view in views {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return (points, y + rowHeight)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        return CGSize(width: width, height: positions(subviews, width: width).height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = positions(subviews, width: bounds.width)
        for index in subviews.indices {
            subviews[index].place(at: CGPoint(x: bounds.minX + layout.points[index].x, y: bounds.minY + layout.points[index].y), proposal: .unspecified)
        }
    }
}

struct ContributionChart: View {
    var rows: [UsageRow]
    var metric: UsageMetric = .total
    var limit = 8
    @State private var selectedID: String?
    @FocusState private var focusedID: String?
    @Environment(\.appAccent) private var accent
    private var ranked: [UsageRow] {
        rows.filter { metric.amount($0.tokens) > 0 }.sorted {
            let a = metric.amount($0.tokens), b = metric.amount($1.tokens)
            return a == b ? $0.id < $1.id : a > b
        }
    }
    var body: some View {
        let shown = Array(ranked.prefix(limit))
        let maximum = max(1, shown.first.map { metric.amount($0.tokens) } ?? 1)
        VStack(alignment: .leading, spacing: 14) {
            if shown.isEmpty { Text("No recorded usage in this selection.").foregroundStyle(.secondary).padding(.vertical, PageStyle.section) }
            ForEach(shown) { row in
                rowButton(row, maximum: maximum)
            }
            if ranked.count > limit { Text("Top \(limit) of \(ranked.count.formatted()). Export CSV includes every matching record.").font(.caption).foregroundStyle(.secondary) }
            if let row = rows.first(where: { $0.id == selectedID }) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(row.title).font(.headline)
                    Text(row.subtitle.isEmpty ? row.id : row.subtitle).font(.caption).foregroundStyle(.secondary)
                    ReadAgeCaption(date: row.last, prefix: "\(metric.amount(row.tokens).formatted()) \(metric.rawValue.lowercased()) tokens · Last activity", includesClock: false).font(.callout)
                }.textSelection(.enabled).padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private func rowButton(_ row: UsageRow, maximum: Int) -> some View {
        let amount: Int = metric.amount(row.tokens)
        let fraction: Double = Double(amount) / Double(maximum)
        let isSelected: Bool = selectedID == row.id
        let accessibilityText: String = row.title + ", " + String(amount) + " " + metric.rawValue + " tokens"
        return Button {
            if isSelected { selectedID = nil } else { selectedID = row.id }
        } label: {
            ContributionBar(title: row.title, value: amount, fraction: fraction, selected: isSelected)
        }
        .buttonStyle(.plain)
        .focused($focusedID, equals: row.id)
        .padding(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(focusedID == row.id ? Color.primary.opacity(0.6) : .clear, lineWidth: 2))
        .help(isSelected ? "Hide contribution details" : "Show contribution details")
        .accessibilityHint("Show or hide contribution details")
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

}

private struct ContributionBar: View {
    var title: String
    var value: Int
    var fraction: Double
    var selected: Bool
    @Environment(\.appAccent) private var accent
    var body: some View {
        VStack(alignment: .leading, spacing: PageStyle.labelGap) {
            HStack {
                Text(title).lineLimit(1)
                Spacer(minLength: 16)
                Text(compact(value)).monospacedDigit().foregroundStyle(.secondary)
                Image(systemName: selected ? "chevron.down" : "chevron.right").font(.caption).foregroundStyle(.secondary)
            }.font(.callout)
            ProgressView(value: fraction)
                .progressViewStyle(ReportMagnitudeStyle(emphasized: selected))
                .accessibilityHidden(true) // The enclosing button exposes the exact token value.
        }.contentShape(Rectangle())
    }
}
