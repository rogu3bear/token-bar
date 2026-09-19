import SwiftUI

struct PromptInsightsSection: View {
    var state: PromptReadState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appAccent) private var accent
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Codex prompt patterns").font(PageStyle.sectionTitle)
            Text("Last 30 days · up to 120 recently active human chats").font(.caption).foregroundStyle(.secondary)
            readStatus
            if state.failed { ErrorNotice(message: state.message) }
            else if state.isPartial || state.result?.prompts == 0 {
                Text(state.message).foregroundStyle(.secondary)
            }
            if let result = state.result {
                if let warning = result.cacheWarning {
                    StatusNotice(message: warning, severity: .warning, dismissible: false)
                }
                HStack(alignment: .top, spacing: PageStyle.related) {
                    stat("PROMPTS", result.prompts.formatted())
                    stat("TYPICAL LENGTH", result.prompts == 0 ? "—" : "\(result.medianWords) words")
                    stat("CHATS IN SAMPLE", result.tasks.formatted())
                }.frame(maxWidth: .infinity)
                if result.prompts > 0 {
                    if result.prompts >= 10, result.hours.count > 1, let hour = result.hours.first {
                        Text("Busiest sampled hour: \(hour.label) · \(hour.count) prompts, in local time.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if !result.repeats.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Prompts you returned to").font(.headline)
                            Text("Exact repeats after normalizing case and spacing; up to 300 characters. Repetition alone does not establish a recurring task.")
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(Array(result.repeats.prefix(3))) { fact in
                                HStack(alignment: .top, spacing: 16) {
                                    Text(fact.label).font(.callout).textSelection(.enabled)
                                    Spacer(minLength: 8)
                                    Text("\(fact.count) times").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                DetailSheet("About this sample") {
                Text("\(result.files) logs in sample · \(result.tasks) chats with prompts. Saved statistics are reused; only changed chats are processed. Prompt text is not saved. Copied message IDs count once; older logs use turn/message pairs. Agent messages, known setup messages, fenced code and quoted lines are excluded from word statistics. The displayed repeats and busiest hour describe this sample, not all your activity.")
                    .font(.caption).foregroundStyle(.secondary)
                }
                if result.skipped > 0 {
                    StatusNotice(message: "\(result.skipped) logs were unavailable or incomplete.", severity: .warning, dismissible: false)
                }

            }
        }
    }
    /// A fixed status slot keeps refreshes from moving the findings under the pointer.
    private var readStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            if state.loading {
                Text(state.checkingCaption)
                if let total = state.filesTotal, total > 0 {
                    ProgressView(value: Double(state.filesChecked), total: Double(total))
                        .progressViewStyle(.linear).accessibilityLabel("Reading prompt history")
                        .animation(reduceMotion ? nil : .linear(duration: 0.2), value: state.filesChecked)
                }
            } else if let date = state.result?.readAt {
                HStack(spacing: 4) {
                    Text(state.isPartial ? "Partial sample read" : "Results read")
                    RelativeAgeText(date: date)
                    Text("ago · " + date.formatted(date: .abbreviated, time: .shortened))
                }
            } else if !state.failed {
                Text(state.message)
            }
        }.font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 42, maxHeight: 42, alignment: .leading)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: state.loading)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        SummaryMetric(title: label, value: value)
    }
}
