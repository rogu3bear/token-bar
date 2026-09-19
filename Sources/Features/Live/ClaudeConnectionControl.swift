import SwiftUI

/// Connect or disconnect Claude Code's status line from the Token Bar relay.
/// Shown in the Claude quota panel and in Menu bar settings.
struct ClaudeConnectionControl: View {
    @Bindable var model: ClaudeConnectionModel
    var compact = false
    @State private var confirming = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("Claude Code status line · " + model.status.label)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 4)
                if model.status == .notConnected {
                    Button("Connect Claude Code") { confirming = true }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                } else {
                    Button("Disconnect") { model.disconnect() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
            if !compact && model.status == .notConnected {
                Text(ClaudeQuotaSource.connectionCaption)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let caveat = model.caveat { Text(caveat).font(.caption).foregroundStyle(.secondary) }
            if let error = model.error { ErrorNotice(message: error) }
        }
        .alert("Connect Claude Code?", isPresented: $confirming) {
            Button("Connect") { model.connect() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.explanation)
        }
    }
}
