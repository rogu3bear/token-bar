import SwiftUI

/// Now's remaining, speed header, gauge and detail share one provider-column layout.
struct NowOccupancyStack<Remaining: View, Header: View, Gauge: View, Footer: View>: View {
    var working: [LiveTool]
    @ViewBuilder var remaining: (LiveTool) -> Remaining
    @ViewBuilder var header: (LiveTool) -> Header
    @ViewBuilder var gauge: (LiveTool) -> Gauge
    @ViewBuilder var footer: (LiveTool) -> Footer
    var body: some View {
        ProviderColumnsLayout(nowColumns: working.count) {
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
