import SwiftUI

/// Window operations belong to the AppKit host. Feature views receive commands
/// through their host environment; data models never own window callbacks.
struct NativeCommands {
    var reports: (Destination?) -> Void = { _ in }
    var settings: () -> Void = {}
}
private struct NativeCommandsKey: EnvironmentKey {
    static let defaultValue = NativeCommands()
}
extension EnvironmentValues {
    var nativeCommands: NativeCommands {
        get { self[NativeCommandsKey.self] }
        set { self[NativeCommandsKey.self] = newValue }
    }
}
enum ReportWindowGeometry {
    static let width: CGFloat = 1120
    static let height: CGFloat = 800
    static let minWidth: CGFloat = 900
    static let minHeight: CGFloat = 700
}
