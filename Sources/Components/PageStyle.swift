import SwiftUI

/// Dashboard presentation roles. Compact menu content keeps its own density.
enum PageStyle {
    static let gutter: CGFloat = 28
    static let section: CGFloat = 24
    static let reportSection: CGFloat = 18
    static let related: CGFloat = 16
    static let labelGap: CGFloat = 6
    static let title = Font.system(size: 28, weight: .semibold, design: .rounded)
    static let sectionTitle = Font.title2.weight(.semibold)
    static let metric = Font.system(size: 28, weight: .semibold, design: .rounded)
    static let detailMetric = Font.title3
}

/// Features own content and actions; this component owns their shared header rhythm.
struct PageHeader<Actions: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var actions: () -> Actions

    init(_ title: String, subtitle: String? = nil, @ViewBuilder actions: @escaping () -> Actions) {
        self.title = title
        self.subtitle = subtitle
        self.actions = actions
    }

    var body: some View {
        HStack(alignment: .top, spacing: PageStyle.related) {
            VStack(alignment: .leading, spacing: PageStyle.labelGap) {
                Text(title).font(PageStyle.title)
                if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
            }
            Spacer(minLength: PageStyle.related)
            HStack(spacing: 8) { actions() }.controlSize(.regular)
        }
    }
}

extension PageHeader where Actions == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}

/// Values are formatted by the feature; unavailable values remain explicit.
struct SummaryMetric: View {
    var title: String
    var value: String
    var detail: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: PageStyle.labelGap) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(PageStyle.metric).monospacedDigit()
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Recorded contributions share a magnitude style, not import-progress styling.
/// ProgressView retains its native value semantics; selection belongs to its caller.
struct ReportMagnitudeStyle: ProgressViewStyle {
    @Environment(\.appAccent) private var accent
    var emphasized = false
    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                if let fraction = configuration.fractionCompleted, fraction > 0 {
                    Capsule().fill(accent.opacity(emphasized ? 1 : 0.85))
                        .frame(width: max(3, geometry.size.width * CGFloat(fraction)))
                }
            }
        }.frame(height: 10)
    }
}
