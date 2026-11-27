import Charts
import SwiftUI

/// Model, data, reviews and quality in one sheet: the "map database" side of the app.
struct ControlCenterView: View {
    let model: SiteModel
    @State private var tab: ControlTab
    @Environment(\.dismiss) private var dismiss

    init(model: SiteModel, initialTab: ControlTab) {
        self.model = model
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Section", selection: $tab) {
                    ForEach(ControlTab.allCases) { tab in
                        Text(tab == .reviews && !model.pendingReports.isEmpty
                             ? "\(tab.title) (\(model.pendingReports.count))" : tab.title)
                            .tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

                switch tab {
                case .model: ModelTab(model: model)
                case .data: DataTab(model: model)
                case .reviews: ReviewsTab(model: model)
                case .quality: QualityTab(model: model)
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private var navigationTitle: String {
        switch tab {
        case .model: "How the AI scores"
        case .data: "Data and freshness"
        case .reviews: "Review reports"
        case .quality: "Quality checks"
        }
    }
}

// MARK: - Model

private struct ModelTab: View {
    let model: SiteModel
    @State private var confirmingReset = false

    var body: some View {
        List {
            Section {
                FlowStep(number: 1, title: "What the AI looks at", detail: "Six inputs for every street block in the area")
                FlowStep(number: 2, title: "What it predicts", detail: "Demand score (0–100), expected orders at lunch, after school and in the evening, and sales taken from the nearest CDC")
                FlowStep(number: 3, title: "Result", detail: "A ranked shortlist, each spot with a confidence level and the cheapest format to start with")
                FlowStep(number: 4, title: "People decide", detail: "The team approves or skips each pick, and reviews reports before the map changes")
                FlowStep(number: 5, title: "It learns", detail: "Real locker orders update the weights below")
            } header: {
                Text("How a spot gets picked")
            }

            Section {
                ForEach(Feature.allCases) { feature in
                    WeightRow(feature: feature, value: model.weights[feature], total: model.weights.total,
                              onChange: { model.setWeight(feature, to: $0) },
                              onCommit: { model.commitWeights() })
                }
            } header: {
                Text("Inputs and learned weights")
            } footer: {
                Text("Drag a slider to see the shortlist re-rank on the map. Rivals and rent lower a score; the rest raise it.")
            }

            Section {
                if model.pilotRounds.isEmpty {
                    Text("No pilots yet. Run one from the shortlist to see the model learn.")
                        .font(.footnote)
                        .foregroundStyle(Theme.mute)
                } else {
                    Chart {
                        ForEach(model.pilotRounds) { round in
                            LineMark(x: .value("Round", round.id), y: .value("Error", round.errorBefore * 100))
                                .foregroundStyle(Theme.brown)
                                .symbol(Circle())
                        }
                    }
                    .chartXAxisLabel("Pilot round")
                    .chartYAxisLabel("Prediction error, %")
                    .chartXAxis { AxisMarks(values: model.pilotRounds.map(\.id)) }
                    .frame(height: 150)
                    .padding(.vertical, 6)

                    ForEach(model.pilotRounds.reversed()) { round in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Round \(round.id): error \(percent(round.errorBefore)) → \(percent(round.errorAfter))")
                                .font(.subheadline.weight(.semibold))
                            Text(round.results.map { "\($0.letter) \(Int($0.predicted.rounded())) predicted, \(Int($0.actual.rounded())) actual" }
                                .joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(Theme.mute)
                        }
                    }
                }
            } header: {
                Text("Pilot history")
            } footer: {
                Text("Error is how far predicted orders were from actual locker orders, before the model learned from that round.")
            }

            Section {
                Button("Reset the model", role: .destructive) { confirmingReset = true }
            } footer: {
                Text("Resets the weights and clears pilot rounds. Reports, data changes and team decisions stay.")
            }
        }
        .confirmationDialog("Reset the weights and clear all pilot rounds?", isPresented: $confirmingReset,
                            titleVisibility: .visible) {
            Button("Reset", role: .destructive) { model.resetModel() }
        }
    }
}

struct FlowStep: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.footnote.weight(.bold))
                .foregroundStyle(PinColor.brown)
                .frame(width: 26, height: 26)
                .background(PinColor.yellow, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(Theme.mute)
            }
        }
    }
}

struct WeightRow: View {
    let feature: Feature
    let value: Double
    let total: Double
    let onChange: (Double) -> Void
    let onCommit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: feature.symbol).foregroundStyle(Theme.brown).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(feature.title).font(.subheadline.weight(.semibold))
                    Text(feature.source).font(.caption).foregroundStyle(Theme.mute)
                }
                Spacer()
                Text("\(feature.isPenalty ? "−" : "")\(Int((value / max(total, 0.01) * 100).rounded()))%")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(feature.isPenalty ? Theme.red : Theme.ink)
            }
            Slider(value: Binding(get: { value }, set: onChange), in: 0.02...0.6) { editing in
                if !editing { onCommit() }
            }
            .accessibilityLabel("\(feature.title) weight")
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Data

private struct DataTab: View {
    let model: SiteModel
    @State private var confirmingReset = false

    var body: some View {
        List {
            Section {
                ForEach(Feature.allCases) { feature in
                    HStack(spacing: 10) {
                        Image(systemName: feature.symbol).foregroundStyle(Theme.brown).frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(feature.title).font(.subheadline.weight(.semibold))
                            Text(feature.source + ".").font(.caption).foregroundStyle(Theme.mute)
                            Text(feature.updated).font(.caption2.weight(.semibold)).foregroundStyle(Theme.mute)
                        }
                        Spacer()

                    }
                }
            } header: {
                Text("Inputs and when they were last updated")
            }

            Section {
                ForEach(model.districtRows.sorted { $0.district.index < $1.district.index }) { row in
                    let coverage = row.expectedStores > 0 ? Double(row.mappedStores) / row.expectedStores : 1
                    HStack {
                        Text(row.district.name).font(.subheadline)
                        Spacer()
                        if coverage < 0.6 {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.amber)
                        }
                        Text("\(row.mappedStores) of ~\(Int(row.expectedStores.rounded()))")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(coverage < 0.6 ? Theme.amber : Theme.mute)
                    }
                }
            } header: {
                Text("CDC stores mapped, by district")
            } footer: {
                Text("Expected counts share \(AreaData.estimatedStoreTotal) stores by population. Where coverage is thin, \"no CDC nearby\" may be a data gap, so those spots get lower confidence. CDC's own store list would close this.")
            }

            Section {
                if model.stalePlaces.isEmpty {
                    Label("Every place was confirmed in the last \(Freshness.staleAfterDays) days.", systemImage: "checkmark.seal.fill")
                        .font(.footnote)
                        .foregroundStyle(Theme.green)
                } else {
                    ForEach(model.stalePlaces.prefix(15)) { place in
                        HStack(spacing: 10) {
                            PinView(kind: place.kind).scaleEffect(0.8)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(place.name).font(.subheadline.weight(.semibold))
                                Text("\(place.detail) · not confirmed for \(Freshness.duration(days: place.confirmedDaysAgo))")
                                    .font(.caption).foregroundStyle(Theme.mute)
                            }
                            Spacer()
                            Button("Confirm") { model.confirmOpen(place.id) }
                                .font(.footnote.weight(.semibold))
                                .buttonStyle(.bordered)
                                .tint(Theme.brown)
                        }
                    }
                }
                if model.stalePlaces.count > 15 {
                    Text("and \(model.stalePlaces.count - 15) more").font(.footnote).foregroundStyle(Theme.mute)
                }
            } header: {
                Text("Stores and rivals that need a check (\(model.stalePlaces.count))")
            } footer: {
                Text("Not checked on OpenStreetMap, or listed only in the May 2023 branch list, for over two years. Out-of-date places cause the worst map mistakes.")
            }

            Section {
                if model.appliedEdits.isEmpty {
                    Text("No changes yet. Approved reports and confirmations appear here.")
                        .font(.footnote).foregroundStyle(Theme.mute)
                } else {
                    ForEach(model.appliedEdits.reversed()) { applied in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(applied.summary).font(.subheadline)
                                Text(applied.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(Theme.mute)
                            }
                            Spacer()
                            Button("Undo") { model.undo(applied) }.font(.footnote.weight(.semibold))
                        }
                    }
                }
            } header: {
                Text("Changes applied to the map")
            }

            Section {
                let skipped = model.decisions.compactMap { id, decision -> (Int, String)? in
                    if case .skipped(let reason) = decision { return (id, reason) }
                    return nil
                }.sorted { $0.0 < $1.0 }
                if skipped.isEmpty {
                    Text("No spots skipped.").font(.footnote).foregroundStyle(Theme.mute)
                } else {
                    ForEach(skipped, id: \.0) { id, reason in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(model.block(id).map { model.directions(to: $0.center).short } ?? "Street block")
                                    .font(.subheadline)
                                Text(reason).font(.caption).foregroundStyle(Theme.mute)
                            }
                            Spacer()
                            Button("Restore") { model.clearDecision(id) }.font(.footnote.weight(.semibold))
                        }
                    }
                }
            } header: {
                Text("Spots the team skipped")
            }

            Section {
                Label("Homes are counted per 280 m street block from public building data, never per person.", systemImage: "square.grid.3x3")
                Label("With real Club 100 orders, blocks with fewer than 20 orders a week would be merged with neighbours.", systemImage: "person.3")
                Label("Pilots use locker totals only. Nobody's order history leaves the Club 100 system.", systemImage: "lock.fill")
                Label("Your location is used only on this phone to find the block you're in. It isn't stored.", systemImage: "location")
            } header: {
                Text("Privacy")
            } footer: {
                Text("Collect only what the model needs, as the maps report recommends. Sample rules for the concept.")
            }
            .font(.footnote)

            Section {
                Button("Reset the whole demo", role: .destructive) { confirmingReset = true }
            } footer: {
                Text("Restores the starting weights, data and report queue, and clears decisions and recent searches.")
            }
        }
        .confirmationDialog("Reset everything to the starting demo?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset everything", role: .destructive) { model.resetEverything() }
        }
    }
}

// MARK: - Reviews

private struct ReviewsTab: View {
    let model: SiteModel

    var body: some View {
        List {
            Section {
                if model.pendingReports.isEmpty {
                    Label("Nothing waiting. New reports appear here before they change the map.", systemImage: "tray")
                        .font(.footnote)
                        .foregroundStyle(Theme.mute)
                } else {
                    ForEach(model.pendingReports) { report in
                        ReportRow(model: model, report: report)
                    }
                }
            } header: {
                Text("Waiting for review")
            } footer: {
                Text("Tiered trust, like Waze's map editors: anyone can report, on-site reports come first, and only a reviewer changes the map. The automated check flags reports that clash with listings or sales data.")
            }

            if !model.reviewedReports.isEmpty {
                Section("Reviewed") {
                    ForEach(model.reviewedReports) { report in
                        ReportRow(model: model, report: report)
                    }
                }
            }
        }
    }
}

private struct ReportRow: View {
    let model: SiteModel
    let report: Report

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: report.kind.symbol)
                    .foregroundStyle(Theme.brown)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(report.kind.title).font(.subheadline.weight(.semibold))
                    Text(model.title(for: report.target)).font(.footnote)
                    Text("\(report.role.title) · \(report.role.trust) · \(report.created.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(Theme.mute)
                }
            }
            if !report.note.isEmpty {
                Text("“\(report.note)”").font(.footnote).italic().foregroundStyle(Theme.ink)
            }
            CheckBadge(check: report.check)

            switch report.status {
            case .pending:
                HStack(spacing: 10) {
                    Button { model.approve(report) } label: {
                        HStack(spacing: 6) { Image(systemName: "checkmark"); Text("Approve") }.frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.brownFill)
                    Button { model.reject(report) } label: {
                        HStack(spacing: 6) { Image(systemName: "xmark"); Text("Reject") }.frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.red)
                }
                .font(.footnote.weight(.semibold))
            case .approved:
                Label("Approved · map updated", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(Theme.green)
            case .rejected:
                Label("Rejected · map unchanged", systemImage: "xmark.circle.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(Theme.mute)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct CheckBadge: View {
    let check: AutoCheck

    var body: some View {
        let (color, symbol): (Color, String) = switch check.verdict {
        case .agrees: (Theme.green, "checkmark.shield.fill")
        case .disagrees: (Theme.red, "exclamationmark.shield.fill")
        case .unsure: (Theme.amber, "questionmark.diamond.fill")
        }
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                Text(check.verdict.title)
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(color)
            Text(check.detail)
                .font(.caption)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Quality

private struct QualityTab: View {
    let model: SiteModel

    var body: some View {
        let benchmark = model.searchBenchmark
        List {
            Section {
                ForEach(model.qualityMetrics) { metric in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: symbol(for: metric.passes))
                            .foregroundStyle(color(for: metric.passes))
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(metric.title).font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(metric.value).font(.subheadline.monospacedDigit().weight(.bold))
                            }
                            Text(metric.detail).font(.caption).foregroundStyle(Theme.mute)
                            Text("Target: \(metric.target)").font(.caption2.weight(.semibold)).foregroundStyle(Theme.mute)
                        }
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Metrics worth tracking")
            } footer: {
                Text("From the maps report: ETA error becomes prediction error, route acceptance becomes how often the team accepts a pick.")
            }

            Section {
                ForEach(SearchBenchmark.cases, id: \.query) { testCase in
                    let first = model.search(testCase.query).first
                    let passed = first?.title.contains(testCase.expected) ?? false
                    HStack {
                        Image(systemName: passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(passed ? Theme.green : Theme.red)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("“\(testCase.query)”").font(.footnote.weight(.semibold))
                            Text("\(testCase.note) → \(first?.title ?? "no result")").font(.caption).foregroundStyle(Theme.mute)
                        }
                    }
                }
            } header: {
                Text("Search test set: \(benchmark.passed) of \(benchmark.total) right first")
            } footer: {
                Text("Real queries the team types, kept as a regression test. The same set runs in the unit tests.")
            }
        }
    }

    private func symbol(for passes: Bool?) -> String {
        switch passes {
        case .some(true): "checkmark.circle.fill"
        case .some(false): "exclamationmark.triangle.fill"
        case .none: "circle.dashed"
        }
    }

    private func color(for passes: Bool?) -> Color {
        switch passes {
        case .some(true): Theme.green
        case .some(false): Theme.amber
        case .none: Theme.mute
        }
    }
}
