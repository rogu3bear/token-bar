import SwiftUI

/// A small marker beside a figure whose derivation is not the obvious one.
///
/// The badge is only rendered for approximate figures. Every provenance,
/// approximate or not, gets the question mark, because "how was this counted"
/// is a fair question even when the answer is "exactly as reported".
struct ProvenanceBadge: View {
    var provenance: Provenance
    @State private var showing = false

    var body: some View {
        HStack(spacing: 4) {
            if let badge = provenance.badge {
                Text(badge)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .accessibilityLabel("Approximate")
            }
            Button { showing.toggle() } label: {
                Image(systemName: "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(provenance.title + ". " + provenance.explanation)
            .accessibilityLabel("How this number was counted")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(provenance.title).font(.headline)
                    Text(provenance.explanation).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                .padding(PageStyle.related).frame(width: 320)
                .textSelection(.enabled)
            }
        }
    }
}

/// A dismissible explanation shown when a surprising derivation is in play.
///
/// Two ways out, deliberately different. "OK" acknowledges this sighting and
/// lets the note return later. "Don't show again" is the durable opt-out.
struct ProvenanceNotice: View {
    var provenance: Provenance
    @Bindable var notices: ProvenanceNotices
    /// Acknowledged for this viewing only; nothing is written down.
    @State private var acknowledged = false
    @Environment(\.appAccent) private var accent

    var body: some View {
        if notices.shouldShow(provenance) && !acknowledged {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill").foregroundStyle(accent)
                    Text(provenance.title).font(.headline)
                    if let badge = provenance.badge {
                        Text(badge).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(provenance.explanation)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button("OK") { acknowledged = true }
                        .help("Dismiss this note for now. It can appear again later.")
                    Button("Don't show again") { notices.silence(provenance) }
                        .help("Never show this particular explanation again.")
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }
}

/// Presentation only: the ledger report remains the authority for admission.
struct IntegrityPresentation {
    var report: IntegrityReport
    var status: String? {
        guard !report.isClean else { return nil }
        var parts = ["Data integrity"]
        if report.total > 0 { parts.append("\(report.total.formatted()) \(report.total == 1 ? "record" : "records") excluded") }
        if report.repairedTotal > 0 { parts.append("\(report.repairedTotal.formatted()) \(report.repairedTotal == 1 ? "record" : "records") repaired") }
        return parts.joined(separator: " · ")
    }
    static let semantics = "Untrustworthy records remain excluded from displayed totals. Records with repaired subordinate fields remain counted, with those fields corrected downward; their input + output total is unchanged."
    static let retention = "Nothing was deleted. Source records remain unchanged."
}

/// Always present while the report is affected. Only its details can close.
struct IntegrityBanner: View {
    var report: IntegrityReport
    @State private var showingDetails = false
    var body: some View {
        if let status = IntegrityPresentation(report: report).status {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).accessibilityHidden(true)
                Text(status).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                Button("Details") { showingDetails = true }
                    .accessibilityLabel("Data integrity details")
                    .accessibilityHint("Shows exact excluded and repaired record counts and their explanations")
            }.font(.callout)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(status)
                .sheet(isPresented: $showingDetails) {
                    VStack(alignment: .leading, spacing: PageStyle.related) {
                        Text("Data integrity").font(.title2.bold())
                        ScrollView {
                            IntegrityDetails(report: report)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        SheetDoneButton { showingDetails = false }
                    }.padding(PageStyle.section).frame(width: 560, height: 440)
                        .onExitCommand { showingDetails = false }
                }
        }
    }
}

struct IntegrityDetails: View {
    var report: IntegrityReport
    var body: some View {
        VStack(alignment: .leading, spacing: PageStyle.related) {
            LabeledContent("Records excluded", value: report.total.formatted())
            LabeledContent("Records counted with repaired fields", value: report.repairedTotal.formatted())
            Divider()
            ForEach(report.explanations, id: \.self) { line in
                Text(line).fixedSize(horizontal: false, vertical: true)
            }
            Text(IntegrityPresentation.semantics)
            Text(IntegrityPresentation.retention).fontWeight(.medium)
        }.font(.callout).textSelection(.enabled)
    }
}
