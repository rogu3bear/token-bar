import SwiftUI

/// History and Cost edit the same report scope through the same controls.
struct ReportFilters: View {
    @Bindable var model: UsageModel
    var includesCost = false

    // Keep a selected value visible even if a subsequent read no longer lists it.
    private func choices(_ values: [String], selected: String, all: String) -> [String] {
        [all] + Set(values + (selected == all ? [] : [selected])).subtracting([all]).sorted()
    }
    private var accountChoices: [(String, String)] {
        var result = [("All accounts", "All accounts"), ("Unattributed", "Unattributed")]
        result += model.availableAccounts.map { ($0.id, $0.label + " (inferred)") }
        if !result.contains(where: { $0.0 == model.accountFilter }) { result.append((model.accountFilter, "Selected account")) }
        return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.toolFilter != "All tools" { removal("Tool: " + model.toolFilter) { model.toolFilter = "All tools" } }
            if model.modelFilter != "All models" { removal("Model: " + model.modelFilter) { model.modelFilter = "All models" } }
            if model.accountFilter != "All accounts" {
                removal("Account: " + (accountChoices.first(where: { $0.0 == model.accountFilter })?.1 ?? "Selected account")) { model.accountFilter = "All accounts" }
            }
            if !model.search.isEmpty { removal("Search: " + model.search) { model.search = "" } }
            if includesCost && model.costEffort != "All levels" { removal("Reasoning: " + model.costEffort + " · Cost only") { model.costEffort = "All levels" } }
            DetailSheet("Change filters") {
                VStack(alignment: .leading, spacing: 12) {
                    ChoiceRow(title: "Tool", selection: $model.toolFilter, choices: choices(model.availableTools, selected: model.toolFilter, all: "All tools").map { ($0, $0) })
                    ChoiceRow(title: "Model", selection: $model.modelFilter, choices: choices(model.availableModels, selected: model.modelFilter, all: "All models").map { ($0, $0) })
                    ChoiceRow(title: "Account", selection: $model.accountFilter, choices: accountChoices)
                    HStack {
                        ReportSearchField(text: $model.search)
                        Button("Clear filters") { model.clearReportFilters(includesCost: includesCost) }.buttonStyle(.bordered)
                    }
                    if includesCost {
                        ChoiceRow(title: "Reasoning level (Cost only)", selection: $model.costEffort,
                                  choices: choices(model.availableEfforts, selected: model.costEffort, all: "All levels").map { ($0, $0) })
                    }
                    Text(includesCost
                         ? "Clear filters keeps your dates and pricing choices."
                         : "Clear filters keeps your dates.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 8)
            }
            if model.filtering {
                Text("Updating the report. Previous results remain visible until the selected report is ready. Export is unavailable while updating.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func removal(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(label, systemImage: "xmark.circle") }
            .buttonStyle(.plain).help("Remove " + label)
            .accessibilityLabel("Remove filter: " + label)
    }
}

struct ReportPeriodFilter: View {
    @Bindable var model: UsageModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ChoiceRow(title: "Period · local time", selection: $model.period,
                      choices: model.periodChoices)
            if model.period == 4 {
                HStack {
                    DatePicker("From", selection: $model.startDate, displayedComponents: .date).datePickerStyle(.field)
                    DatePicker("Through", selection: $model.endDate, displayedComponents: .date).datePickerStyle(.field)
                    Spacer()
                }
                if Calendar.current.startOfDay(for: model.startDate) > Calendar.current.startOfDay(for: model.endDate) {
                    StatusNotice(message: "Choose an end date on or after the start date.", severity: .warning, dismissible: false)
                }
            }
        }
    }
}

/// Native search editing, clear affordance and keyboard behavior without toolbar relocation.
struct ReportSearchField: NSViewRepresentable {
    @Binding var text: String
    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search task name, ID, or folder"
        field.setAccessibilityLabel("Search task name, ID, or folder")
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
    }
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
