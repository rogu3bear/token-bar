import SwiftUI

/// Settings owner for the optional launch-time update check. The toggle is the
/// only persisted state; results live for the process.
struct UpdateCheckControl: View {
    @Bindable var check: UpdateCheck
    var allowsNetwork: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Check for updates when Token Bar starts", isOn: $check.enabled).disabled(!allowsNetwork)
            Text("Reads the public release list at token-bar-9v8.pages.dev once at launch and compares it with this version on your Mac. No usage, account or version details are sent. Downloads stay a manual step in your browser.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button(check.checking ? "Checking…" : "Check now") { check.check() }
                    .disabled(!allowsNetwork || check.checking)
                if let status = UpdateCheckStatus.text(check) {
                    Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if check.availableRelease != nil {
                    Button("Download") { _ = check.openDownload() }
                }
            }
        }
    }
}

/// Popover row shown only while a newer notarized release is listed.
struct UpdateAvailableNotice: View {
    @Bindable var check: UpdateCheck
    var release: ReleaseManifest
    @Environment(\.appAccent) private var accent
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "arrow.down.circle").foregroundStyle(accent).accessibilityHidden(true)
            Text("Token Bar \(release.version) is available.").font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Download") { _ = check.openDownload() }.controlSize(.small)
        }
        .moduleSurface(padding: 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Update available: Token Bar \(release.version)")
    }
}
