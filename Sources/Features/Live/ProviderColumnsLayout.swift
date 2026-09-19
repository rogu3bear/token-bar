import SwiftUI

/// Equal provider widths and shared row heights keep separators and gauges aligned,
/// including when one provider has additional connection or unavailable text.
struct ProviderColumnsLayout: Layout {
    var columns: Int
    var horizontalSpacing: CGFloat = 48
    var verticalSpacing: CGFloat = 12
    /// Identity rows stacked above the gauge (remaining, then speed header).
    var leadingIntrinsicRows: Int = 1
    /// Model/error detail under the gauge uses the speed header's measure.
    var trailingIntrinsicRows: Int = 1
    /// Row that owns the column's text width; remaining and footer copy it.
    var headerRow: Int = 0
    private func columnWidth(_ width: CGFloat) -> CGFloat {
        max(0, (width - horizontalSpacing * CGFloat(columns - 1)) / CGFloat(columns))
    }
    func separatorPositions(width: CGFloat) -> [CGFloat] {
        let cell = columnWidth(width)
        return (1..<columns).map { CGFloat($0) * (cell + horizontalSpacing) - horizontalSpacing / 2 }
    }
    private func rowCount(_ subviews: Subviews) -> Int {
        columns == 0 ? 0 : (subviews.count + columns - 1) / columns
    }
    private func isIntrinsic(row: Int, rows: Int) -> Bool {
        row < leadingIntrinsicRows || rows - 1 - row < trailingIntrinsicRows
    }
    private func contentWidth(_ cell: CGFloat, index: Int, subviews: Subviews) -> CGFloat {
        // Identity rows keep an intrinsic text/control width on the same
        // horizontal center as the dial instead of stretching left.
        let rows = rowCount(subviews)
        let row = index / max(columns, 1)
        guard isIntrinsic(row: row, rows: rows) else { return cell }
        let column = index % max(columns, 1)
        let headerIndex = min(headerRow * columns + column, subviews.count - 1)
        let header = subviews[headerIndex]
        let proposed = min(cell, header.sizeThatFits(.unspecified).width)
        return min(cell, header.sizeThatFits(ProposedViewSize(width: proposed, height: nil)).width)
    }
    private func dimensions(_ width: CGFloat, subviews: Subviews) -> (CGFloat, [CGFloat]) {
        let cell = columnWidth(width)
        let heights = stride(from: 0, to: subviews.count, by: columns).map { start in
            (start..<min(start + columns, subviews.count)).map {
                subviews[$0].sizeThatFits(ProposedViewSize(width: contentWidth(cell, index: $0, subviews: subviews), height: nil)).height
            }.max() ?? 0
        }
        return (cell, heights)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 900
        let (_, heights) = dimensions(width, subviews: subviews)
        return CGSize(width: width, height: heights.reduce(0, +) + CGFloat(max(0, heights.count - 1)) * verticalSpacing)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (cell, heights) = dimensions(bounds.width, subviews: subviews)
        var y = bounds.minY
        for (row, height) in heights.enumerated() {
            for column in 0..<columns {
                let index = row * columns + column
                guard index < subviews.count else { continue }
                let width = contentWidth(cell, index: index, subviews: subviews)
                subviews[index].place(at: CGPoint(x: bounds.minX + CGFloat(column) * (cell + horizontalSpacing) + cell / 2, y: y),
                                     anchor: .top, proposal: ProposedViewSize(width: width, height: height))
            }
            y += height + verticalSpacing
        }
    }
}

extension ProviderColumnsLayout {
    /// Remaining row plus the speed header that owns column width.
    static let nowLeadingIntrinsicRows = 2
    /// Speed header row; remaining copies its measure so remaining.midX == gauge.midX.
    static let nowHeaderRow = 1

    init(nowColumns columns: Int) {
        self.init(columns: columns, leadingIntrinsicRows: Self.nowLeadingIntrinsicRows, headerRow: Self.nowHeaderRow)
    }
}
