import SwiftUI

/// "Report a problem", from the maps report's checklist. Nothing here changes the map directly:
/// the report goes to the review queue with an automated check attached.
struct ReportSheet: View {
    let model: SiteModel
    let target: ReportTarget
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var kind: ReportKind
    @State private var role: ReporterRole = .fieldScout
    @State private var note = ""

    init(model: SiteModel, target: ReportTarget, title: String) {
        self.model = model
        self.target = target
        self.title = title
        _kind = State(initialValue: ReportKind.options(for: target).first ?? .closed)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(title).font(.subheadline.weight(.semibold))
                } header: {
                    Text("Reporting")
                }

                Section("What's wrong?") {
                    Picker("Problem", selection: $kind) {
                        ForEach(ReportKind.options(for: target)) { option in
                            Label(option.title, systemImage: option.symbol).tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section {
                    Picker("Who's reporting", selection: $role) {
                        ForEach(ReporterRole.allCases) { role in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(role.title)
                                Text(role.trust).font(.caption).foregroundStyle(Theme.mute)
                            }
                            .tag(role)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Who's reporting?")
                } footer: {
                    Text("Reports from people on site are reviewed first. Nobody's report changes the map until a reviewer approves it.")
                }

                Section("Note (optional)") {
                    TextField("What did you see?", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .navigationTitle("Report a problem")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        model.submitReport(target: target, kind: kind, role: role, note: note)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
    }
}
