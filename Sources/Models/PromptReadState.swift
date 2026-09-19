import Foundation

/// Availability belongs to the read, not to the numeric values in its sample.
struct PromptReadState {
    private(set) var result: PromptInsights?
    private(set) var loading = false
    private(set) var failed = false
    private(set) var completed = false
    private(set) var filesChecked = 0
    private(set) var filesTotal: Int?
    var isPartial: Bool { result != nil && (!completed || result!.skipped > 0) }
    var message: String {
        if failed {
            if result == nil { return "Prompt insights unavailable. The local prompt history could not be read. It will retry automatically when this page is open." }
            return completed ? "Refresh failed. Previous results are retained and may be stale." : "Read failed. The partial sample is retained; it is incomplete."
        }
        if loading { return result == nil ? "Reading your recent human prompts locally…" : "Refreshing… Showing the last available sample while the read completes." }
        guard let result else { return "Prompt patterns will update automatically when local history is ready." }
        if isPartial { return "Partial results. Some prompt logs were unavailable or incomplete." }
        return result.prompts == 0 ? "Read completed. No human prompts were found in the sampled period." : "Results from the last completed local read."
    }
    mutating func begin() { loading = true; failed = false; filesChecked = 0; filesTotal = nil }
    mutating func receivePartial(_ sample: PromptInsights) {
        filesChecked = sample.filesChecked; filesTotal = sample.filesTotal
        guard !completed, sample.files > 0 else { return }
        result = sample
    }
    mutating func succeed(_ sample: PromptInsights) {
        guard sample.skipped == 0 || sample.files > 0 else { fail(); return }
        result = sample; completed = true; loading = false; failed = false
    }
    mutating func fail() { loading = false; failed = true }
    /// Known remaining is only a count when the read has a total. Missing total stays “finding,” not 0 remaining.
    var remainingFiles: Int? { filesTotal.map { max(0, $0 - filesChecked) } }
    var checkingCaption: String {
        guard let total = filesTotal, let remaining = remainingFiles else {
            return "Finding recent chats in the background…"
        }
        return "Checking prompt history · \(filesChecked) of \(total) files · \(remaining) remaining"
    }
}
