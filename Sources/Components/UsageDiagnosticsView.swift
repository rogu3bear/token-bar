import SwiftUI

/// Shared usage evidence for Live, History and Cost. Presentation never clears
/// a diagnostic or changes admitted usage.
struct UsageDiagnosticsView: View {
    var health: UsageReadHealth
    @State private var showingDetails = false
    var body: some View {
        if !health.diagnostics.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label(health.summary, systemImage: health.failed ? "exclamationmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(health.failed ? Color.red : .orange)
                    .textSelection(.enabled)
                Button("View diagnostic details") { showingDetails = true }
            }.font(.callout).padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background((health.failed ? Color.red : .orange).opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .sheet(isPresented: $showingDetails) { UsageDiagnosticDetails(health: health) }
        }
    }
}

struct UsageDiagnosticDetails: View {
    var health: UsageReadHealth
    @Environment(\.dismiss) private var dismiss
    @State private var filter = "All issues"
    private var filtered: [UsageDiagnostic] {
        health.diagnostics.filter {
            filter == "All issues" || (filter == "Read failures" ? $0.isFailure : !$0.isFailure)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Usage diagnostics").font(.title2)
            Text(health.summary).font(.callout)
            Text("Live and history may report the same file separately. A retained gap does not establish lost usage. Supported later usage can resume while the earlier gap remains.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Show", selection: $filter) {
                ForEach(["All issues", "Coverage warnings", "Read failures"], id: \.self) { Text($0) }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(filtered) { diagnostic in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(diagnostic.provider + " · " + diagnostic.scope.rawValue.capitalized).font(.headline)
                            Text(diagnostic.message)
                            if let source = diagnostic.source { Text(source).font(.caption.monospaced()) }
                            if !diagnostic.isFailure {
                                Text(recovery(diagnostic.recovery)).foregroundStyle(.secondary)
                            }
                            if let first = diagnostic.firstChecked {
                                Text("First recorded by this version " + first.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Text("\(filtered.count.formatted()) reported issues").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 660, height: 480).onExitCommand { dismiss() }
    }
    private func recovery(_ value: UsageDiagnostic.Recovery) -> String {
        switch value {
        case .unresolved: return "Earlier counter boundary remains unresolved."
        case .resumed: return "Supported usage has an admitted boundary; the historical gap remains."
        case .unknown: return "Recovery has not been established."
        }
    }
}
