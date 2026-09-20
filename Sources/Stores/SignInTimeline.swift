import Observation
import Foundation
import Combine

struct SignInObservation: Codable, Identifiable {
    var id = UUID().uuidString
    var date: Date
    var account: Account?
    var reason: String
    var status: String?
}
@Observable final class SignInTimeline {
    var observations: [SignInObservation] = []
    var error: String?
    private let home: URL
    private let file: URL
    @ObservationIgnored private var canWrite = true
    init(home: URL, file: URL) {
        self.home = home; self.file = file
        if FileManager.default.fileExists(atPath: file.path) {
            do { observations = try JSONDecoder().decode([SignInObservation].self, from: Data(contentsOf: file)) }
            catch { self.error = "Sign-in timeline could not be read; original preserved."; canWrite = false }
        }
    }
    var lastSwitchDate: Date? {
        observations.last { ($0.reason == "Credential-file change observed" && $0.account != nil) || ($0.status?.hasPrefix("Login") == true) }?.date
    }
    func observe(start: Bool = false) {
        guard canWrite else { return }
        let account = Account.read(home: home)
        if !start, let last = observations.last, last.account?.id == account?.id, last.account?.plan == account?.plan { return }
        var next = observations
        next.append(SignInObservation(date: Date(), account: account, reason: start ? "Monitor started · observation gap before this point" : "Credential-file change observed"))
        do {
            try PrivateCache.write(next, to: file)
            observations = next; error = nil
        } catch { self.error = "Sign-in timeline could not be saved: " + error.localizedDescription }
    }
}
