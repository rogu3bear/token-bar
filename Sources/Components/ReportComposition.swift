import SwiftUI

struct CompositionPart: Identifiable {
    var id: String
    var amount: Double
    var value: String
}

/// Disjoint measured components. Zero has no segment; labels remain available.
struct ReportComposition: View {
    var parts: [CompositionPart]
    @Environment(\.appAccent) private var accent
    private var total: Double { parts.reduce(0) { $0 + $1.amount } }
    private func ink(_ index: Int) -> Color { accent.opacity(max(0.4, 1 - Double(index) * 0.14)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if total > 0 {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        ForEach(Array(parts.enumerated()), id: \.element.id) { index, part in
                            if part.amount > 0 {
                                Rectangle().fill(ink(index)).frame(width: geometry.size.width * part.amount / total)
                            }
                        }
                    }.clipShape(RoundedRectangle(cornerRadius: 4))
                }.frame(height: 10).accessibilityHidden(true)
            }
            ChoiceFlow(spacing: 16) {
                ForEach(Array(parts.enumerated()), id: \.element.id) { index, part in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(ink(index)).frame(width: 8, height: 8)
                        Text(part.id)
                        Text(part.value).monospacedDigit().fontWeight(.medium)
                        if total > 0 {
                            Text((part.amount / total).formatted(.percent.precision(.fractionLength(0))))
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                    }.font(.callout).accessibilityElement(children: .combine)
                }
            }
        }
    }
}
