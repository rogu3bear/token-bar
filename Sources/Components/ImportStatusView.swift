import SwiftUI

/// The same import status stays visible across dashboard destinations and the popover.
struct ImportStatusView: View {
    @Bindable var model: UsageModel
    var inset: CGFloat = 28
    var body: some View {
        if let progress = model.progress {
            VStack(alignment: .leading, spacing: 6) {
                Text(progress.title).font(.callout.weight(.medium))
                if let fraction = progress.fraction {
                    HStack(spacing: 10) {
                        ProgressView(value: fraction).progressViewStyle(.linear).accessibilityLabel(progress.title)
                        Text(fraction, format: .percent.precision(.fractionLength(0))).monospacedDigit().font(.caption)
                    }
                }
                Text(progress.detail).font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, inset).padding(.vertical, 6)
        } else if model.filtering {
            VStack(alignment: .leading, spacing: 6) {
                Text(ReportUpdateCopy.title).font(.callout)
                Text(ReportUpdateCopy.waiting).font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, inset).padding(.vertical, 6)
        }
    }
}
