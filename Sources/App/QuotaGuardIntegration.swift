import Foundation
import Observation

extension UsageModel {
    func guardInputs() -> [QuotaGuardInput] {
        LiveTool.allCases.map { tool in
            let state = quota(for: tool)
            return QuotaGuardInput(tool: tool, accountID: state.guardAccountID, readings: state.readings, samples: state.samples,
                horizon: state.horizon, authenticated: state.guardAuthenticated, failed: state.guardFailed)
        }
    }
}

extension AppDelegate {
    func observeQuotaGuard() {
        let inputs = withObservationTracking {
            model.guardInputs()
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.observeQuotaGuard() }
        }
        model.quotaGuard.update(inputs)
    }
}
