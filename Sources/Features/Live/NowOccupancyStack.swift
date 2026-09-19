import SwiftUI

/// Idle Now copy. Occupied columns have no empty line; missing tools are not "not working".
enum NowOccupancyCopy {
    static let noneWorking = "No tools working right now"
    static let noSources = "No account sources detected yet. Open a supported tool to begin."

    /// Popover empty line: sources or working, never both sentences.
    static func line(sourcesKnown: Bool, occupied: Bool) -> String? {
        if occupied { return nil }
        return sourcesKnown ? noneWorking : noSources
    }

    /// Dashboard Now keeps the allowance empty-state; this line is only idle-with-sources.
    static func noneWorkingLine(sourcesKnown: Bool, occupied: Bool) -> String? {
        !occupied && sourcesKnown ? noneWorking : nil
    }
}

/// Now's remaining, speed header, gauge and detail share one provider-column layout.
struct NowOccupancyStack<Remaining: View, Header: View, Gauge: View, Footer: View>: View {
    var working: [LiveTool]
    @ViewBuilder var remaining: (LiveTool) -> Remaining
    @ViewBuilder var header: (LiveTool) -> Header
    @ViewBuilder var gauge: (LiveTool) -> Gauge
    @ViewBuilder var footer: (LiveTool) -> Footer
    var body: some View {
        ProviderColumnsLayout(columns: working.count, leadingIntrinsicRows: 2, headerRow: 1) {
            ForEach(working) { tool in
                remaining(tool)
            }
            ForEach(working) { tool in
                header(tool)
            }
            ForEach(working) { tool in
                gauge(tool)
            }
            ForEach(working) { _ in Divider() }
            ForEach(working) { tool in
                footer(tool)
            }
        }
    }
}
