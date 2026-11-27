import Charts
import SwiftUI

struct SheetRoot: View {
    @Bindable var model: SiteModel
    let usesGoogle: Bool

    var body: some View {
        NavigationStack(path: $model.path) {
            ShortlistView(model: model, usesGoogle: usesGoogle)
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .spot(let id):
                        if let spot = model.spot(forBlock: id) {
                            SpotDetailView(model: model, spot: spot)
                        } else if let block = model.block(id) {
                            BlockDetailView(model: model, block: block)
                        }
                    case .block(let id):
                        if let block = model.block(id) { BlockDetailView(model: model, block: block) }
                    case .place(let id):
                        if let place = model.place(id) {
                            PlaceDetailView(model: model, place: place)
                        } else {
                            ContentUnavailableView("Removed from the map", systemImage: "mappin.slash",
                                                   description: Text("An approved report removed this place."))
                        }
                    case .compare:
                        CompareView(model: model)
                    case .districts:
                        DistrictRankingView(model: model)
                    }
                }
        }
    }
}

// MARK: - Shortlist

struct ShortlistView: View {
    let model: SiteModel
    let usesGoogle: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let best = model.bestSpot {
                    BestPlaceCard(model: model, spot: best)
                }

                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Top \(model.spots.count) across \(AreaData.name)").font(Theme.heading(.title3))
                        Text("\(model.blocks.count.formatted()) street blocks scored · at most two spots per district")
                            .font(.footnote)
                            .foregroundStyle(Theme.mute)
                    }
                    Spacer()
                    if model.spots.count >= 2 {
                        Button { model.open(.compare) } label: {
                            Label("Compare", systemImage: "square.split.2x1")
                                .font(.footnote.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .tint(Theme.brown)
                    }
                }

                VStack(spacing: 0) {
                    ForEach(model.spots) { spot in
                        Button { model.open(.spot(spot.id)) } label: {
                            SpotRow(spot: spot, confidence: model.confidence(for: spot.block),
                                    directions: model.directions(to: spot.block.center),
                                    approved: model.decision(for: spot.id)?.isApproved == true)
                        }
                        .buttonStyle(.plain)
                        if spot.id != model.spots.last?.id { Divider().padding(.leading, 52) }
                    }
                }
                .cardStyle()

                if !model.pendingReports.isEmpty {
                    Button { model.controlTab = .reviews } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "tray.full.fill").foregroundStyle(Theme.red)
                            Text("\(model.pendingReports.count) reports waiting for review")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.ink)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Theme.mute)
                        }
                        .padding(12)
                        .cardStyle()
                    }
                    .buttonStyle(.plain)
                }

                PilotCard(model: model)

                VStack(alignment: .leading, spacing: 6) {
                    if !usesGoogle {
                        Label("Map: Apple Maps preview. Add a Google Maps key to switch (see README).", systemImage: "map")
                    }
                    Text("Places and homes: © OpenStreetMap contributors (ODbL), with 2021 Census district totals and the published CDC branch list. Orders, reports and pilot results are modelled, not measured.")
                }
                .font(.caption)
                .foregroundStyle(Theme.mute)
            }
            .padding(16)
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

struct SpotRow: View {
    let spot: Spot
    let confidence: Confidence
    let directions: Wayfinding.Directions
    let approved: Bool

    var body: some View {
        HStack(spacing: 12) {
            SpotPinView(letter: spot.letter, selected: false)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(spot.kind.rawValue).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                    if approved {
                        Image(systemName: "checkmark.seal.fill").font(.caption).foregroundStyle(Theme.green)
                            .accessibilityLabel("Approved for a pilot")
                    }
                }
                Text("\(directions.short) · \(AreaData.districts[spot.block.district].name)")
                    .font(.caption)
                    .foregroundStyle(Theme.mute)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text("Score \(spot.block.score)").font(.subheadline.weight(.bold)).foregroundStyle(Theme.brownSoft)
                Text("~\(Int(spot.block.netOrders.rounded()))/day · \(spot.format.rawValue)")
                    .font(.caption)
                    .foregroundStyle(Theme.mute)
                ConfidenceChip(level: confidence.level, compact: true)
            }
            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Theme.mute)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct PilotCard: View {
    let model: SiteModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("It learns", systemImage: "arrow.triangle.2.circlepath")
                .font(Theme.heading(.subheadline))
                .foregroundStyle(Theme.brown)
            Text("Put lockers at three spots for 4 weeks (approved spots go first). Real orders update the model, so each new pick is better than the last.")
                .font(.footnote)
                .foregroundStyle(Theme.ink)

            if let last = model.pilotRounds.last {
                HStack(spacing: 16) {
                    MiniStat(value: "\(model.pilotRounds.count)", label: "pilot rounds")
                    MiniStat(value: percent(last.errorBefore), label: "error before")
                    MiniStat(value: percent(last.errorAfter), label: "error after")
                }
            }

            Button { withAnimation { model.runPilot() } } label: {
                Label(model.pilotRounds.isEmpty ? "Run a 4-week locker pilot" : "Run the next pilot round",
                      systemImage: "play.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.brownFill)
            .disabled(model.spots.isEmpty)
        }
        .padding(14)
        .background(Theme.cream, in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Spot detail

struct SpotDetailView: View {
    let model: SiteModel
    let spot: Spot
    @State private var reporting = false
    @State private var choosingSkipReason = false

    var body: some View {
        let block = spot.block
        let confidence = model.confidence(for: block)
        let directions = model.directions(to: block.center)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    SpotPinView(letter: spot.letter, selected: true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(spot.title).font(Theme.heading(.title3))
                        HStack(spacing: 8) {
                            Text("Rank \(spot.rank) of \(model.spots.count)").font(.footnote).foregroundStyle(Theme.mute)
                            ConfidenceChip(level: confidence.level)
                        }
                    }
                }

                WhyCallout(text: model.why(block))

                HStack(spacing: 10) {
                    StatTile(value: "\(block.score)", unit: "/ 100", label: "Demand score")
                    StatTile(value: "~\(Int(block.netOrders.rounded()))", unit: "a day", label: "New orders",
                             note: "\(confidence.rangeText) likely")
                    StatTile(value: Explain.percentText(block.cannibalisation), unit: "", label: "Taken from CDC",
                             note: "\(block.nearestStore.name), \(Geo.formatDistance(block.storeDistance))")
                }

                DirectionsCard(directions: directions)

                DecisionCard(model: model, spot: spot, choosingSkipReason: $choosingSkipReason)

                RecommendationCard(format: spot.format)

                SectionTitle("How sure is this?")
                ConfidenceCard(confidence: confidence)

                SectionTitle("Why the AI picked it")
                InputBars(block: block, weights: model.weights)

                SectionTitle("Expected orders by time of day")
                OrdersChart(orders: block.orders.scaled(by: 1 - block.cannibalisation))

                ExternalLinks(coordinate: block.center)

                ReportButton { reporting = true }
            }
            .padding(16)
        }
        .navigationTitle("Spot \(spot.letter)")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $reporting) {
            ReportSheet(model: model, target: .block(block.id), title: spot.title)
        }
        .confirmationDialog("Why skip Spot \(spot.letter)?", isPresented: $choosingSkipReason, titleVisibility: .visible) {
            ForEach(SiteModel.skipReasons, id: \.self) { reason in
                Button(reason) { model.skipSpot(spot.id, reason: reason) }
            }
        } message: {
            Text("The next best block takes its place. Skips are tracked, so the team can see what the model keeps getting wrong.")
        }
    }
}

/// The human call on an AI pick: approve it for a pilot, or skip it with a reason.
struct DecisionCard: View {
    let model: SiteModel
    let spot: Spot
    @Binding var choosingSkipReason: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.decision(for: spot.id)?.isApproved == true {
                HStack {
                    Label("Approved for the next locker pilot", systemImage: "checkmark.seal.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.green)
                    Spacer()
                    Button("Undo") { model.clearDecision(spot.id) }.font(.subheadline)
                }
            } else {
                Text("Your call: approve it for the next locker pilot, or skip it with a reason.")
                    .font(.caption)
                    .foregroundStyle(Theme.mute)
                HStack(spacing: 10) {
                    Button { model.approveSpot(spot.id) } label: {
                        Label("Approve", systemImage: "checkmark").frame(maxWidth: .infinity).frame(height: 40)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.brownFill)
                    Button { choosingSkipReason = true } label: {
                        Label("Skip", systemImage: "arrow.uturn.down").frame(maxWidth: .infinity).frame(height: 40)
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.brown)
                }
                .font(.subheadline.weight(.semibold))
            }
        }
        .padding(14)
        .cardStyle()
    }
}

struct RecommendationCard: View {
    let format: StartFormat

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: format.symbol)
                .font(.title3.weight(.bold))
                .foregroundStyle(PinColor.brown)
                .frame(width: 44, height: 44)
                .background(PinColor.yellow, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text("Start with a \(format.rawValue.lowercased())").font(Theme.heading())
                Text(format.detail).font(.footnote).foregroundStyle(Theme.ink)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cream, in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Block detail

struct BlockDetailView: View {
    let model: SiteModel
    let block: Block
    @State private var reporting = false

    var body: some View {
        let excludedReason = model.excludedBlocks[block.id]
        let skipped: Bool = {
            if case .skipped = model.decision(for: block.id) { return true }
            return false
        }()
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Street block").font(Theme.heading(.title3))
                    Text(excludedReason == nil ? "Not shortlisted" : "Taken off the shortlist")
                        .font(.footnote).foregroundStyle(Theme.mute)
                }

                WhyCallout(text: model.why(block))

                HStack(spacing: 10) {
                    StatTile(value: "\(block.score)", unit: "/ 100", label: "Demand score")
                    StatTile(value: "~\(Int(block.netOrders.rounded()))", unit: "a day", label: "New orders")
                    StatTile(value: Explain.percentText(block.cannibalisation), unit: "", label: "Taken from CDC",
                             note: "\(block.nearestStore.name), \(Geo.formatDistance(block.storeDistance))")
                }

                DirectionsCard(directions: model.directions(to: block.center))

                VStack(alignment: .leading, spacing: 10) {
                    Label(model.engine.exclusionReason(for: block, spots: model.spots, excluded: model.excludedBlocks),
                          systemImage: "info.circle.fill")
                        .font(.footnote)
                    if skipped {
                        Button("Put it back on the shortlist") { model.clearDecision(block.id) }
                            .font(.footnote.weight(.semibold))
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.cream, in: RoundedRectangle(cornerRadius: 14))

                SectionTitle("What drives this score")
                InputBars(block: block, weights: model.weights)

                ExternalLinks(coordinate: block.center)

                ReportButton { reporting = true }
            }
            .padding(16)
        }
        .navigationTitle("Street block")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $reporting) {
            ReportSheet(model: model, target: .block(block.id), title: "Street block: \(model.directions(to: block.center).short)")
        }
    }
}

// MARK: - Place detail

struct PlaceDetailView: View {
    let model: SiteModel
    let place: Place
    @State private var reporting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    PinView(kind: place.kind)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(place.kind == .cdcStore ? "Café de Coral · \(place.name)" : place.name)
                            .font(Theme.heading(.title3))
                        Text("\(place.nameZH) · \(place.kind.title)").font(.footnote).foregroundStyle(Theme.mute)
                    }
                }

                Text(place.detail).font(.subheadline)

                FreshnessCard(place: place) { model.confirmOpen(place.id) }

                if place.kind == .cdcStore {
                    let served = model.blocks.filter { $0.nearestStore.id == place.id && $0.storeDistance < SiteEngine.minimumStoreGap }
                    let nearbySpots = model.spots.filter { $0.block.nearestStore.id == place.id }
                    HStack(spacing: 10) {
                        StatTile(value: "\(served.count)", unit: "blocks", label: "Already covers",
                                 note: "within \(Int(SiteEngine.minimumStoreGap)) m")
                        StatTile(value: "\(nearbySpots.count)", unit: "", label: "Shortlisted spots nearby")
                    }
                    if !nearbySpots.isEmpty {
                        SectionTitle("Spots that would take sales from this store")
                        VStack(spacing: 0) {
                            ForEach(nearbySpots) { spot in
                                Button { model.open(.spot(spot.id)) } label: {
                                    HStack {
                                        SpotPinView(letter: spot.letter, selected: false)
                                        Text(spot.kind.rawValue).font(.subheadline.weight(.semibold))
                                        Spacer()
                                        Text("\(Explain.percentText(spot.block.cannibalisation)) of its orders")
                                            .font(.caption).foregroundStyle(Theme.mute)
                                    }
                                    .padding(10)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .cardStyle()
                    }
                } else {
                    Text(placeRole(place.kind)).font(.footnote).foregroundStyle(Theme.mute)
                }

                if !place.aliases.isEmpty {
                    Text("Also found by searching: \(place.aliases.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(Theme.mute)
                }

                ExternalLinks(coordinate: place.coordinate)

                ReportButton { reporting = true }
            }
            .padding(16)
        }
        .navigationTitle(place.kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $reporting) {
            ReportSheet(model: model, target: .place(place.id),
                        title: place.kind == .cdcStore ? "Café de Coral · \(place.name)" : place.name)
        }
    }

    private func placeRole(_ kind: PlaceKind) -> String {
        switch kind {
        case .school, .university: "Feeds the \"Schools and campuses\" input. Universities count about twice as much as a secondary school."
        case .office: "Feeds the \"Offices and young workers\" input, which mostly drives lunch orders."
        case .mtr: "Feeds the \"Footfall and MTR exits\" input."
        case .rival: "Feeds the \"Rivals nearby\" input, which lowers nearby scores. Shown as a category, not a real outlet."
        case .cdcStore: ""
        }
    }
}

/// When someone last confirmed the place is real and open. Stale data is the most common way
/// a map goes wrong, so it's shown on every place, not hidden in a settings screen.
struct FreshnessCard: View {
    let place: Place
    let confirm: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: place.isStale ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                .foregroundStyle(place.isStale ? Theme.amber : Theme.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(place.isStale ? "Needs a check" : "Confirmed open \(Freshness.describe(daysAgo: place.confirmedDaysAgo))")
                    .font(.subheadline.weight(.semibold))
                if place.isStale {
                    Text("Nobody has confirmed it for \(Freshness.duration(days: place.confirmedDaysAgo)).")
                        .font(.caption).foregroundStyle(Theme.mute)
                }
            }
            Spacer()
            if place.confirmedDaysAgo > 0 {
                Button("Confirm open", action: confirm)
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.bordered)
                    .tint(Theme.brown)
            }
        }
        .padding(12)
        .cardStyle()
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Shared pieces

struct WhyCallout: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lightbulb.fill").foregroundStyle(PinColor.yellow)
            Text(text).font(.subheadline).foregroundStyle(Theme.ink)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cream, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}

/// Landmark-based directions in English and Chinese, the way people in Hong Kong give them.
struct DirectionsCard: View {
    let directions: Wayfinding.Directions

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "figure.walk").foregroundStyle(Theme.brown).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text("How to find it").font(.caption.weight(.bold)).foregroundStyle(Theme.mute)
                Text(directions.english).font(.subheadline)
                Text(directions.chinese).font(.subheadline).foregroundStyle(Theme.mute)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .accessibilityElement(children: .combine)
    }
}

struct ConfidenceChip: View {
    let level: Confidence.Level
    var compact = false
    var showsIcon = true

    var body: some View {
        let color: Color = switch level {
        case .high: Theme.green
        case .medium: Theme.amber
        case .low: Theme.red
        }
        HStack(spacing: 4) {
            if showsIcon { Image(systemName: symbol) }
            Text(compact ? level.title : "\(level.title) confidence")
        }
            .font(.caption2.weight(.bold))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
            .accessibilityLabel("\(level.title) confidence")
    }

    private var symbol: String {
        switch level {
        case .high: "checkmark.circle.fill"
        case .medium: "circle.lefthalf.filled"
        case .low: "exclamationmark.circle.fill"
        }
    }
}

struct ConfidenceCard: View {
    let confidence: Confidence

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ConfidenceChip(level: confidence.level)
                Spacer()
                Text("\(confidence.rangeText) new orders a day").font(.subheadline.weight(.semibold))
            }
            Text(confidence.reason).font(.footnote).foregroundStyle(Theme.ink)
            Text("Checked by re-scoring with each weight 30% higher and lower. Only a pilot can raise confidence to High.")
                .font(.caption)
                .foregroundStyle(Theme.mute)
        }
        .padding(14)
        .cardStyle()
    }
}

struct ReportButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Report a problem", systemImage: "exclamationmark.bubble")
                .font(.footnote.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 40)
        }
        .buttonStyle(.bordered)
        .tint(Theme.mute)
    }
}

/// The six inputs as signed bars: what each one adds to (or takes off) this block's score.
struct InputBars: View {
    let block: Block
    let weights: Weights

    var body: some View {
        let contributions = Feature.allCases.map { ($0, block.contribution($0, weights: weights)) }
        let largest = max(contributions.map { abs($0.1) }.max() ?? 1, 0.01)
        VStack(spacing: 10) {
            ForEach(contributions, id: \.0) { feature, value in
                HStack(spacing: 10) {
                    Image(systemName: feature.symbol)
                        .font(.footnote)
                        .foregroundStyle(Theme.brown)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(feature.title).font(.footnote.weight(.semibold))
                            Spacer()
                            Text(level(block.features[feature] ?? 0)).font(.caption).foregroundStyle(Theme.mute)
                        }
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(value >= 0 ? PinColor.yellow : Theme.red.opacity(0.75))
                                .frame(width: max(3, geo.size.width * abs(value) / largest))
                        }
                        .frame(height: 8)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(feature.title): \(level(block.features[feature] ?? 0)), \(value >= 0 ? "raises" : "lowers") the score")
            }
            Text("Yellow raises the score, red lowers it. Bar length is the input times its learned weight.")
                .font(.caption)
                .foregroundStyle(Theme.mute)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .cardStyle()
    }

    private func level(_ value: Double) -> String {
        switch value {
        case ..<0.15: "Very low"
        case ..<0.35: "Low"
        case ..<0.6: "Medium"
        case ..<0.8: "High"
        default: "Very high"
        }
    }
}

struct OrdersChart: View {
    let orders: Orders

    var body: some View {
        let rows = [("Lunch", orders.lunch), ("After school", orders.afterSchool), ("Evening", orders.evening)]
        Chart(rows, id: \.0) { row in
            BarMark(x: .value("Orders", row.1), y: .value("Time", row.0))
                .foregroundStyle(PinColor.yellow)
                .cornerRadius(4)
                .annotation(position: .trailing) {
                    Text("\(Int(row.1.rounded()))").font(.caption.weight(.semibold)).foregroundStyle(Theme.ink)
                }
        }
        .chartXAxis(.hidden)
        .frame(height: 110)
        .padding(14)
        .cardStyle()
    }
}

struct ExternalLinks: View {
    let coordinate: Coordinate

    var body: some View {
        HStack(spacing: 10) {
            Link(destination: ExternalMaps.googleMapsURL(coordinate)) {
                Label("Open in Google Maps", systemImage: "map.fill").frame(maxWidth: .infinity).frame(height: 40)
            }
            Link(destination: ExternalMaps.streetViewURL(coordinate)) {
                Label("Street View", systemImage: "binoculars.fill").frame(maxWidth: .infinity).frame(height: 40)
            }
        }
        .font(.footnote.weight(.semibold))
        .buttonStyle(.bordered)
        .tint(Theme.brown)
    }
}

struct StatTile: View {
    let value: String
    let unit: String
    let label: String
    var note: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(Theme.mute).lineLimit(1).minimumScaleFactor(0.8)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.title3.weight(.bold)).foregroundStyle(Theme.ink)
                Text(unit).font(.caption).foregroundStyle(Theme.mute)
            }
            if let note {
                Text(note).font(.caption2).foregroundStyle(Theme.mute).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .cardStyle()
    }
}

struct MiniStat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.headline).foregroundStyle(Theme.ink)
            Text(label).font(.caption2).foregroundStyle(Theme.mute)
        }
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(Theme.heading(.subheadline)).foregroundStyle(Theme.ink).padding(.top, 2)
    }
}

extension View {
    func cardStyle() -> some View {
        background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line, lineWidth: 1))
    }
}
