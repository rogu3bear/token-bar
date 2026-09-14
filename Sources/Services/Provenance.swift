import Observation
import Foundation

/// How a displayed number came to exist.
///
/// Several figures in this app are not the plain sum a person would assume, and
/// the difference is large enough to matter: Claude Code repeats one message's
/// usage across transcript lines, and its cache counters sit beside input
/// rather than inside it. A number whose derivation is surprising says so.
enum Provenance: String, CaseIterable, Identifiable {
    /// Counted exactly as the tool reported it.
    case measured
    /// The tool repeated a record; each was counted once.
    case deduplicated
    /// Counters were converted into the shared form before being added.
    case converted
    /// Older days are stored as one row per day, not per request.
    case aggregated
    /// Derived from a rate card or an observed rate, not reported by anyone.
    case estimated
    /// Reported by the provider as money, not derived here.
    case providerReported

    var id: String { rawValue }

    /// Whether a reader should treat the figure as approximate.
    var isApproximate: Bool {
        switch self {
        case .measured, .deduplicated, .converted, .providerReported: return false
        case .aggregated, .estimated: return true
        }
    }

    var badge: String? { isApproximate ? "approx." : nil }

    var title: String {
        switch self {
        case .measured: return "Counted as reported"
        case .deduplicated: return "Counted once per message"
        case .converted: return "Converted to a shared form"
        case .aggregated: return "Summarised by day"
        case .estimated: return "Estimated"
        case .providerReported: return "Reported by the provider"
        }
    }

    /// One plain paragraph. No jargon a person would have to look up.
    var explanation: String {
        switch self {
        case .measured:
            return "This is the number the tool itself recorded, added up with nothing inferred."
        case .deduplicated:
            return "Claude Code writes the same message's usage on several lines of its transcript. Repeated identical counters count once. When a later record increases a message’s counters, only the verified increase is added; it does not count as another message."
        case .converted:
            return "Tools disagree about cache counters. Codex counts cached tokens inside its input total, while Claude Code and OpenCode report them separately. Everything here is converted to one form first, so a cached read is never counted twice and never dropped."
        case .aggregated:
            return "Older usage is grouped by day, tool, project and model. Totals stay exact. Retained request evidence can restore timing for matching groups; otherwise only daily detail is available."
        case .estimated:
            return "This is worked out from a dated price list or an observed rate, not reported by the provider. Treat it as an indication, not a bill."
        case .providerReported:
            return "The provider stated this figure itself. It is not an estimate made here, and it is never mixed with one."
        }
    }

    /// Only surprising derivations are worth interrupting someone about.
    var deservesNotice: Bool {
        switch self {
        case .measured, .providerReported: return false
        case .deduplicated, .converted, .aggregated, .estimated: return true
        }
    }
}

/// Remembers which explanations a person has dismissed for good.
///
/// Dismissal is per explanation, not global: silencing the cache-conversion
/// note should not also silence an estimate warning.
@Observable final class ProvenanceNotices {
    private(set) var silenced: Set<String>
    private let defaults: UserDefaults
    private static let key = "provenance.silenced.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        silenced = Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    func shouldShow(_ provenance: Provenance) -> Bool {
        provenance.deservesNotice && !silenced.contains(provenance.rawValue)
    }

    /// "Don't show again" is the only thing that persists. Acknowledging with
    /// OK dismisses the notice for now and lets it return, because a person who
    /// has not opted out should keep being told how a surprising number works.
    func silence(_ provenance: Provenance) {
        silenced.insert(provenance.rawValue)
        defaults.set(Array(silenced).sorted(), forKey: Self.key)
    }

    func restoreAll() {
        silenced = []
        defaults.removeObject(forKey: Self.key)
    }
}
