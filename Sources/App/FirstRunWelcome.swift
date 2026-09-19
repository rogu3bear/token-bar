import SwiftUI

/// A local acknowledgement, not an OS permission or a provider credential.
enum FirstRunAccess {
    static let key = "localAccess.explained.v1"
    static func needsExplanation(_ defaults: UserDefaults) -> Bool { !defaults.bool(forKey: key) }
    static func accept(_ defaults: UserDefaults) { defaults.set(true, forKey: key) }
}

struct LocalAccessExplanation: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            explanation("Local history", "Reads supported tool logs on this Mac and saves token counts in your Application Support folder. Source logs are not changed. Prompt patterns save derived statistics and checkpoints for a limited Codex sample; prompt text stays in memory.")
            explanation("Account allowance", "Uses your installed Codex app-server and Grok agent with existing sign-ins for account and quota readings. Claude remaining comes from Claude Code itself: its usage cache, and its status line after every turn once you choose Connect Claude Code. These tools may contact their services. Claude quota comes from its local cache. You do not enter passwords or API keys here.")
            explanation("Permissions", "Token Bar does not require Accessibility, Screen Recording, or Full Disk Access for its standard locations. If macOS asks for file access, allow only the folder you intend to read. Unreadable sources remain unavailable.")
            explanation("Your choice", "No telemetry or automatic uploads. Exports and feedback are initiated by you. Launch at login is optional in Menu bar settings, as is the update check, which reads only the public release list when the app starts. Quit Token Bar to stop monitoring; your saved history stays on this Mac.")
        }
    }
    private func explanation(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct FirstRunWelcome: View {
    @Environment(\.appAccent) private var accent
    @State private var showPrivacy = false
    var start: () -> Void
    var quit: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Welcome to Token Bar").font(.system(size: 26, weight: .semibold, design: .rounded))
            Text("Token Bar reads local tool history and saves usage counts on this Mac. Account allowance uses existing Codex and Grok sign-ins; those tools may contact their services. No passwords or API keys are needed here.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button { showPrivacy = true } label: { Text("Data & privacy").foregroundStyle(accent) }.buttonStyle(.link)
                .popover(isPresented: $showPrivacy) {
                    VStack(alignment: .leading, spacing: 16) {
                        LocalAccessExplanation()
                        HStack { Spacer(); Button("Done") { showPrivacy = false }.keyboardShortcut(.defaultAction) }
                    }.padding(24).frame(width: 520).onExitCommand { showPrivacy = false }
                }
            HStack {
                Button("Quit", action: quit).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Start local monitoring", action: start).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 600)
            .background(Color(nsColor: .windowBackgroundColor))
    }
    @MainActor static func present() -> Bool {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 350), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Token Bar — Local access"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AppearanceHost(preferences: AppearancePreferences()) {
            FirstRunWelcome(start: { NSApp.stopModal(withCode: .OK) }, quit: { NSApp.stopModal(withCode: .cancel) })
        })
        window.center(); NSApp.activate(ignoringOtherApps: true)
        let response = NSApp.runModal(for: window)
        window.close()
        return response == .OK
    }
    @MainActor static func render(to destination: URL) throws {
        _ = NSApplication.shared
        let suite = "local.tokenbar.welcome-preview." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let appearance = AppearancePreferences(defaults: defaults)
        appearance.websitePreset()
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: AppearanceHost(preferences: appearance) {
            FirstRunWelcome(start: {}, quit: {})
        })
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 350)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        AppearanceRendering.capture(host, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: destination, options: .withoutOverwriting)
        window.close()
    }
}
