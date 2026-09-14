import Foundation

/// How a harness reports cache counters relative to its input counter.
///
/// The three supported harnesses do not agree, and the disagreement is not
/// cosmetic: adding the fields the wrong way either double counts a cached read
/// or drops it entirely.
///
/// - `cachedWithinInput`: Codex. `cached_input_tokens` is a subset of
///   `input_tokens`, so input already includes the cached portion.
/// - `cacheBesideInput`: Claude Code and OpenCode. Cache read and cache write
///   are disjoint from input and must be added to it. Verified against
///   OpenCode's own `total`, which equals input + read + write + output on
///   every row that reports one.
enum TokenConvention {
    case cachedWithinInput
    case cacheBesideInput
}

extension Tokens {
    /// Build the canonical record from whatever a harness reported.
    ///
    /// The canonical form is the Codex form: `cached` is the part of `input`
    /// that was served from cache, so `total` is `input + output` for every
    /// harness and cache share is `cached / input` everywhere. Readers convert
    /// once, here, rather than each teaching the rest of the app its dialect.
    static func canonical(input: Int, cacheRead: Int, cacheWrite: Int,
                          output: Int, reasoning: Int,
                          convention: TokenConvention) -> Tokens {
        var tokens = Tokens()
        switch convention {
        case .cachedWithinInput:
            tokens.input = max(0, input)
            tokens.cached = min(max(0, cacheRead), max(0, input))
        case .cacheBesideInput:
            // Cache reads and writes were context this request consumed, so they
            // belong in input. Without this the request looks far smaller than
            // it was: a Claude Code turn can report 2 input tokens beside 27,000
            // cache reads.
            tokens.input = max(0, input) + max(0, cacheRead) + max(0, cacheWrite)
            tokens.cached = max(0, cacheRead)
        }
        tokens.output = max(0, output)
        tokens.reasoning = min(max(0, reasoning), max(0, output))
        tokens.cacheWrite = cacheWrite >= 0 ? cacheWrite : nil
        return tokens
    }
}
