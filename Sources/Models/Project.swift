import Foundation

/// Harness, provider, model and reasoning setting are four separate dimensions.
/// This file owns the two that were previously unmodeled: the harness that ran a
/// turn, and the project the turn was working in.
///
/// A harness is the client program (Codex Desktop, the Codex CLI, a Grok client).
/// A provider is the account and API behind the model. They are not the same
/// dimension: one harness can reach several providers, and one provider can be
/// reached by several harnesses. Recording only the provider, as this app did,
/// cannot express either fact.
enum Harness {
    /// Local Grok clients do not name themselves in their session files.
    static let grok = "Grok"

    /// The harness that produced a Codex session, from `session_meta.originator`.
    /// Unknown stays unknown: an absent originator is never defaulted to Codex,
    /// because a wrong harness label is worse than a missing one.
    static func codex(originator: Any?) -> String? { label(originator) }

    static func label(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else { return nil }
        return trimmed
    }
}

/// A project is the working directory a turn ran in. The path is evidence; the
/// key is for grouping and the name is for display.
enum Project {
    /// Reject anything that is not a plausible absolute local directory, so a
    /// malformed record cannot invent a project.
    static func path(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), trimmed.count > 1, trimmed.count <= 4096 else { return nil }
        var stripped = trimmed
        while stripped.count > 1 && stripped.hasSuffix("/") { stripped.removeLast() }
        return stripped
    }

    /// Grouping key. macOS filesystems are case-insensitive by default, so
    /// `/Users/x/dev/x` and `/Users/x/Dev/x` are one project observed under
    /// two spellings. Folding case here keeps them from splitting a report in two.
    static func key(_ raw: String?) -> String? {
        guard let resolved = path(raw) else { return nil }
        return resolved.lowercased()
    }

    /// Display name: the final path component, which is what a person calls the
    /// project. The full path stays available as evidence.
    static func name(_ raw: String?) -> String? {
        guard let resolved = path(raw) else { return nil }
        let component = (resolved as NSString).lastPathComponent
        return component.isEmpty ? resolved : component
    }
}
