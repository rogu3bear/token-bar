import Observation
import Foundation
import Combine

@Observable final class InsightsModel {
    private(set) var state = PromptReadState()
    var busy: Bool { state.loading }
    private let queue = DispatchQueue(label: "local.codex-token-bar.insights", qos: .background, autoreleaseFrequency: .workItem)
    @ObservationIgnored private var nextRead = Date.distantPast
    private let clock: () -> Date
    init(clock: @escaping () -> Date = Date.init) { self.clock = clock }

    func refresh(home: URL, force: Bool = false) {
        guard !busy, force || clock() >= nextRead else { return }
        state.begin()
        queue.async {
            var lastPublication = Date.distantPast
            do {
                let result = try InsightReader.read(home: home, now: self.clock(), clock: self.clock) { partial in
                    let now = Date()
                    guard partial.filesChecked == 0 || partial.filesChecked == partial.filesTotal || now.timeIntervalSince(lastPublication) >= 0.5 else { return }
                    lastPublication = now
                    DispatchQueue.main.async { self.state.receivePartial(partial) }
                }
                DispatchQueue.main.async {
                    self.nextRead = self.clock().addingTimeInterval(300)
                    self.state.succeed(result)
                }
            } catch {
                DispatchQueue.main.async {
                    self.nextRead = self.clock().addingTimeInterval(300)
                    self.state.fail()
                }
            }
        }
    }
}
