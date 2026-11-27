import Foundation
import Observation
import SwiftUI

enum SheetDetent {
    static let peekHeight: CGFloat = 168
    static let peek = PresentationDetent.height(peekHeight)
}

/// A change applied to the map database, kept so it can be listed and undone.
struct AppliedEdit: Identifiable, Codable, Hashable {
    let id: UUID
    let edit: DataEdit
    let summary: String
    let reportID: UUID?
    let date: Date
}

/// The team's call on an AI pick: the human in the loop.
enum SpotDecision: Codable, Hashable {
    case approved
    case skipped(reason: String)

    var isApproved: Bool { self == .approved }
}

/// A demand cell to draw: one street block when zoomed in, or a 3×3 group of blocks when
/// the whole territory is on screen (the report's "decide what matters at each zoom level").
struct DrawCell: Identifiable {
    let id: String
    /// The block to open when the cell is tapped (the best block in a group).
    let blockID: Int
    let corners: [Coordinate]
    let score: Int
}

/// The part of the map on screen.
struct MapRegion: Equatable {
    var minLat: Double
    var maxLat: Double
    var minLon: Double
    var maxLon: Double

    static let hongKong = MapRegion(minLat: 22.15, maxLat: 22.57, minLon: 113.82, maxLon: 114.45)

    func contains(_ coordinate: Coordinate) -> Bool {
        (minLat...maxLat).contains(coordinate.latitude) && (minLon...maxLon).contains(coordinate.longitude)
    }

    /// Grown by a share of its size on every side, so cells just off screen are ready when you pan.
    func expanded(by share: Double) -> MapRegion {
        let dLat = (maxLat - minLat) * share, dLon = (maxLon - minLon) * share
        return MapRegion(minLat: minLat - dLat, maxLat: maxLat + dLat, minLon: minLon - dLon, maxLon: maxLon + dLon)
    }
}

/// One row of the district ranking.
struct DistrictRow: Identifiable {
    var id: Int { district.index }
    let district: District
    let best: Block?
    let bestSpot: Spot?
    let mappedStores: Int
    let expectedStores: Double
    /// Residents more than a 5-minute walk (400 m) from a mapped CDC.
    let underserved: Double
}

struct QualityMetric: Identifiable {
    let id: String
    let title: String
    let value: String
    let detail: String
    let target: String
    /// nil when there's nothing to judge yet, or the metric is tracked rather than targeted.
    let passes: Bool?
}

@Observable
final class SiteModel {
    static let defaultZoom: Float = AreaData.defaultZoom
    /// Below this zoom the map shows 3×3 groups of blocks instead of single blocks.
    static let detailZoom = 13.0
    static let skipReasons = ["No space for a locker", "Landlord said no", "Too close to a rival", "Something else"]

    private(set) var data: AreaDataset = .base
    private(set) var engine = SiteEngine()
    private(set) var weights: Weights = .starting
    private(set) var blocks: [Block] = []
    private(set) var blockIndex: [Int: Int] = [:]
    private(set) var spots: [Spot] = []
    private(set) var coarseCells: [DrawCell] = []
    private(set) var districtRows: [DistrictRow] = []
    @ObservationIgnored private var underservedByDistrict: [Double] = []
    private(set) var confidences: [Int: Confidence] = [:]
    /// Bumped whenever scores or data change, so the map knows to redraw.
    private(set) var scoreVersion = 0
    private(set) var pilotRounds: [PilotRound] = []
    private(set) var appliedEdits: [AppliedEdit] = []
    private(set) var reports: [Report] = []
    private(set) var decisions: [Int: SpotDecision] = [:]
    private(set) var recentSearches: [SearchResult] = []

    var layers: Set<MapLayer> = [.demand, .stores]
    var path: [Route] = [] {
        didSet { if path.isEmpty { selection = nil } }
    }
    private(set) var selection: Route?
    var detent: PresentationDetent = SheetDetent.peek
    var cameraRequest = CameraRequest(center: AreaData.center, zoom: SiteModel.defaultZoom)
    var controlTab: ControlTab?
    var toast: Toast?
    /// Pins on screen hidden to avoid overlap, reported by the map.
    var hiddenPinCount = 0

    let location = LocationService()

    @ObservationIgnored private let persists: Bool
    @ObservationIgnored private let storageKey = "siteFinder.state.v2"

    init(persists: Bool = true) {
        self.persists = persists
        let restored = persists && restore()
        rebuild()
        if !restored {
            reports = ReportChecks.seeds(data: data, block: { [unowned self] in self.block($0) }, spots: spots)
            save()
        }
        location.onUpdate = { [weak self] coordinate in self?.handleLocation(coordinate) }
        location.onDenied = { [weak self] in
            self?.showToast("Location is off. Turn it on in Settings to check spots on site.", symbol: "location.slash")
        }
        location.onFailure = { [weak self] in
            self?.showToast("Couldn't find your location. Try again outdoors.", symbol: "location.slash")
        }
    }

    // MARK: Lookups

    func block(_ id: Int) -> Block? { blockIndex[id].map { blocks[$0] } }

    /// The single best place to open next, according to the data: the top of the shortlist.
    var bestSpot: Spot? { spots.first }

    func drawCells(in region: MapRegion?, zoom: Double) -> [DrawCell] {
        let area = region ?? .hongKong
        if zoom < Self.detailZoom {
            return coarseCells.filter { area.contains($0.corners[0]) || area.contains($0.corners[2]) }
        }
        return blocks.compactMap { block in
            guard block.score >= SiteEngine.minimumDrawnScore, area.contains(block.center) else { return nil }
            return DrawCell(id: "b\(block.id)", blockID: block.id, corners: block.corners, score: block.score)
        }
    }
    func spot(forBlock id: Int) -> Spot? { spots.first { $0.block.id == id } }
    func place(_ id: String) -> Place? { data.allPlaces.first { $0.id == id } }

    var drawnBlocks: [Block] { blocks.filter { $0.score >= SiteEngine.minimumDrawnScore } }

    var pendingReports: [Report] {
        reports.filter { $0.status == .pending }
            .sorted { ($0.role.trustRank, $0.created) > ($1.role.trustRank, $1.created) }
    }

    var reviewedReports: [Report] {
        reports.filter { $0.status != .pending }.sorted { ($0.reviewed ?? .distantPast) > ($1.reviewed ?? .distantPast) }
    }

    /// Blocks the shortlist must skip, with the reason shown to the team.
    var excludedBlocks: [Int: String] {
        var result: [Int: String] = [:]
        for (id, decision) in decisions {
            if case .skipped(let reason) = decision { result[id] = "skipped by the team (\(reason.lowercased()))" }
        }
        for applied in appliedEdits {
            if case .excludeBlock(let id, let reason) = applied.edit { result[id] = reason }
        }
        return result
    }

    var stalePlaces: [Place] { data.allPlaces.filter(\.isStale).sorted { $0.confirmedDaysAgo > $1.confirmedDaysAgo } }

    func confidence(for block: Block) -> Confidence {
        confidences[block.id] ?? engine.confidence(for: block, weights: weights, evidence: evidence(for: block.id))
    }

    func evidence(for blockID: Int) -> PilotEvidence? {
        for round in pilotRounds.reversed() {
            if let result = round.results.first(where: { $0.blockID == blockID }) {
                return PilotEvidence(round: round.id, result: result)
            }
        }
        return nil
    }

    func directions(to coordinate: Coordinate) -> Wayfinding.Directions {
        Wayfinding.describe(coordinate, data: data)
    }

    func why(_ block: Block) -> String {
        Explain.why(block, weights: weights, data: data, rank: spot(forBlock: block.id)?.rank)
    }

    func decision(for blockID: Int) -> SpotDecision? { decisions[blockID] }

    func title(for target: ReportTarget) -> String {
        switch target {
        case .place(let id):
            guard let place = place(id) ?? AreaDataset.base.allPlaces.first(where: { $0.id == id }) else { return "A removed place" }
            return place.kind == .cdcStore ? "Café de Coral · \(place.name)" : place.name
        case .block(let id):
            guard let block = block(id) else { return "A street block" }
            if let spot = spot(forBlock: id) { return "\(spot.title)" }
            return "Street block: \(directions(to: block.center).short)"
        }
    }

    // MARK: Selection

    func open(_ route: Route, moveCamera: Bool = true) {
        selection = route
        path = [route]
        if detent == SheetDetent.peek { detent = .medium }
        guard moveCamera else { return }
        switch route {
        case .spot(let id), .block(let id):
            if let block = block(id) { focus(block.center, zoom: 15.6) }
        case .place(let id):
            if let place = place(id) { focus(place.coordinate, zoom: 15.8) }
        case .compare, .districts:
            recenter()
        }
    }

    func tapMap(at coordinate: Coordinate) {
        guard layers.contains(.demand), let id = SiteEngine.Grid.id(at: coordinate),
              let block = block(id), block.score >= SiteEngine.minimumDrawnScore else {
            closeDetail()
            return
        }
        open(spot(forBlock: id) != nil ? .spot(id) : .block(id), moveCamera: false)
    }

    func closeDetail() {
        path = []
        selection = nil
        detent = SheetDetent.peek
    }

    func focus(_ coordinate: Coordinate, zoom: Float) {
        cameraRequest = CameraRequest(center: coordinate, zoom: zoom)
    }

    func recenter() {
        focus(AreaData.center, zoom: Self.defaultZoom)
    }

    func toggle(_ layer: MapLayer) {
        if layers.contains(layer) { layers.remove(layer) } else { layers.insert(layer) }
    }

    // MARK: Model and pilots

    func setWeight(_ feature: Feature, to value: Double) {
        weights[feature] = value
        rescore()
    }

    /// Called when a slider is released, so dragging doesn't write to disk on every tick.
    func commitWeights() { save() }

    /// Spots the team approved go first; the rest of the top three fill in.
    var pilotSites: [Spot] {
        let approved = spots.filter { decisions[$0.id]?.isApproved == true }
        let others = spots.filter { decisions[$0.id]?.isApproved != true }
        return Array((approved + others).prefix(3))
    }

    func runPilot() {
        let sites = pilotSites
        guard !sites.isEmpty else { return }
        let (round, learned) = engine.runPilot(round: pilotRounds.count + 1, weights: weights, spots: sites)
        pilotRounds.append(round)
        weights = learned
        rescore()
        save()
        showToast("Pilot round \(round.id): error \(percent(round.errorBefore)) → \(percent(round.errorAfter)). Shortlist updated.",
                  symbol: "arrow.triangle.2.circlepath")
    }

    func resetModel() {
        weights = .starting
        pilotRounds = []
        rescore()
        save()
    }

    func resetEverything() {
        weights = .starting
        pilotRounds = []
        appliedEdits = []
        decisions = [:]
        recentSearches = []
        rebuild()
        reports = ReportChecks.seeds(data: data, block: { [unowned self] in self.block($0) }, spots: spots)
        closeDetail()
        save()
        showToast("Demo reset to its starting state.", symbol: "arrow.counterclockwise")
    }

    // MARK: Team decisions

    func approveSpot(_ id: Int) {
        decisions[id] = .approved
        rescore()
        save()
        let letter = spot(forBlock: id)?.letter ?? ""
        showToast("Spot \(letter) approved. It goes into the next locker pilot.", symbol: "checkmark.circle.fill")
    }

    func skipSpot(_ id: Int, reason: String) {
        let letter = spot(forBlock: id)?.letter ?? ""
        decisions[id] = .skipped(reason: reason)
        rescore()
        save()
        showToast("Spot \(letter) skipped. The next best block moved onto the shortlist.", symbol: "arrow.uturn.down")
    }

    func clearDecision(_ id: Int) {
        decisions[id] = nil
        rescore()
        save()
    }

    // MARK: Reports and edits

    func submitReport(target: ReportTarget, kind: ReportKind, role: ReporterRole, note: String) {
        let check = ReportChecks.check(kind, target: target, data: data, block: { [unowned self] in self.block($0) })
        let report = Report(id: UUID(), target: target, kind: kind, role: role,
                            note: note.trimmingCharacters(in: .whitespacesAndNewlines), created: Date(),
                            check: check, status: .pending, reviewed: nil)
        reports.insert(report, at: 0)
        save()
        showToast("Sent for review. The map only changes once a reviewer approves it.", symbol: "tray.and.arrow.up.fill")
    }

    func approve(_ report: Report) {
        guard let index = reports.firstIndex(where: { $0.id == report.id }) else { return }
        reports[index].status = .approved
        reports[index].reviewed = Date()
        var center: Coordinate?
        if case .block(let id) = report.target { center = block(id)?.center }
        if let edit = ReportChecks.edit(for: report, blockCenter: center) {
            let summary = "\(report.kind.title): \(title(for: report.target))"
            appliedEdits.append(AppliedEdit(id: UUID(), edit: edit, summary: summary, reportID: report.id, date: Date()))
            if case .place(let id) = report.target, path.contains(.place(id)) { closeDetail() }
            rebuild()
            showToast("Map updated: \(report.kind.title.lowercased()).", symbol: "map.fill")
        }
        save()
    }

    func reject(_ report: Report) {
        guard let index = reports.firstIndex(where: { $0.id == report.id }) else { return }
        reports[index].status = .rejected
        reports[index].reviewed = Date()
        save()
    }

    func undo(_ applied: AppliedEdit) {
        appliedEdits.removeAll { $0.id == applied.id }
        if let reportID = applied.reportID, let index = reports.firstIndex(where: { $0.id == reportID }) {
            reports[index].status = .pending
            reports[index].reviewed = nil
        }
        rebuild()
        save()
    }

    /// A team member confirms a place is still open. Freshness resets to today.
    func confirmOpen(_ placeID: String) {
        guard let place = place(placeID) else { return }
        appliedEdits.append(AppliedEdit(id: UUID(), edit: .confirmPlace(id: placeID),
                                        summary: "Confirmed open: \(place.name)", reportID: nil, date: Date()))
        rebuild()
        save()
        showToast("Marked as confirmed open today.", symbol: "checkmark.seal.fill")
    }

    // MARK: Location

    func locateMe() { location.locate() }

    private func handleLocation(_ coordinate: Coordinate) {
        guard let id = SiteEngine.Grid.id(at: coordinate), let block = block(id) else {
            showToast("You're outside the \(AreaData.name) pilot area.", symbol: "location.slash")
            return
        }
        focus(coordinate, zoom: 16.2)
        if block.score >= SiteEngine.minimumDrawnScore {
            open(spot(forBlock: id) != nil ? .spot(id) : .block(id), moveCamera: false)
            showToast("You're standing in a block that scores \(block.score).", symbol: "location.fill")
        } else {
            showToast("You're here. This block has too little demand to score.", symbol: "location.fill")
        }
    }

    // MARK: Toast

    func showToast(_ message: String, symbol: String) {
        let toast = Toast(message: message, symbol: symbol)
        self.toast = toast
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3.5))
            if self?.toast?.id == toast.id { self?.toast = nil }
        }
    }

    // MARK: Search

    func search(_ text: String) -> [SearchResult] {
        SearchIndex.results(for: text, spots: spots, data: data)
    }

    func choose(_ result: SearchResult) {
        recentSearches.removeAll { $0.id == result.id }
        recentSearches.insert(result, at: 0)
        recentSearches = Array(recentSearches.prefix(5))
        save()
        switch result.target {
        case .route(let route): open(route)
        case .area(let coordinate):
            closeDetail()
            focus(coordinate, zoom: 15.4)
        }
    }

    func clearRecentSearches() {
        recentSearches = []
        save()
    }

    // MARK: Quality

    /// The report's "metrics worth tracking", translated from navigation to site selection.
    var qualityMetrics: [QualityMetric] {
        var metrics: [QualityMetric] = []

        if let last = pilotRounds.last {
            metrics.append(QualityMetric(
                id: "error", title: "Prediction error", value: percent(last.errorBefore),
                detail: "How far predicted orders were from actual locker orders in the latest pilot, before learning. The site-finder version of ETA error.",
                target: "10% or less", passes: last.errorBefore <= 0.10))
        } else {
            metrics.append(QualityMetric(
                id: "error", title: "Prediction error", value: "—",
                detail: "Run a locker pilot to measure how far predictions are from real orders.",
                target: "10% or less", passes: nil))
        }

        let bench = SearchBenchmark.run(spots: spots, data: data)
        metrics.append(QualityMetric(
            id: "search", title: "Search finds it first", value: "\(bench.passed) of \(bench.total)",
            detail: "Test queries whose first result is right, including typos, abbreviations and Chinese names.",
            target: "90% or more", passes: bench.rate >= 0.9))

        let places = data.stores + data.rivals
        let fresh = places.filter { !$0.isStale }.count
        metrics.append(QualityMetric(
            id: "fresh", title: "Stores and rivals checked recently", value: "\(fresh) of \(places.count)",
            detail: "Checked in the last two years. Stale places are the most common way maps go wrong; CDC's live store list and a weekly listings feed would fix this.",
            target: "95% or more", passes: Double(fresh) / Double(max(places.count, 1)) >= 0.95))

        let reviewed = reports.filter { $0.status != .pending }
        let right = reviewed.filter { $0.status == .approved }.count
        metrics.append(QualityMetric(
            id: "precision", title: "Report precision", value: reviewed.isEmpty ? "—" : "\(right) of \(reviewed.count)",
            detail: "Reviewed reports that turned out to be right. If this drops, tighten the automated checks.",
            target: "Tracked", passes: nil))

        let decided = decisions.values
        let approved = decided.filter(\.isApproved).count
        metrics.append(QualityMetric(
            id: "acceptance", title: "Picks the team accepts", value: decided.isEmpty ? "—" : "\(approved) of \(decided.count)",
            detail: "AI picks approved for a pilot. Like drivers rejecting a route, repeated skips show what the model is missing.",
            target: "60% or more", passes: decided.isEmpty ? nil : Double(approved) / Double(decided.count) >= 0.6))

        return metrics
    }

    var searchBenchmark: SearchBenchmark.Result { SearchBenchmark.run(spots: spots, data: data) }

    // MARK: Rebuilding

    private func rebuild() {
        data = AreaDataset.base.applying(appliedEdits.map(\.edit))
        engine = SiteEngine(data: data)
        // People more than a 5-minute walk from a mapped CDC, per district. Weights don't change this.
        var underserved = Array(repeating: 0.0, count: AreaData.districts.count)
        let blocks = engine.blocks(weights: weights)
        let residents = Dictionary(uniqueKeysWithValues: AreaData.raster.map { ($0.id, $0.residents) })
        for block in blocks where block.storeDistance > 400 && underserved.indices.contains(block.district) {
            underserved[block.district] += residents[block.id] ?? 0
        }
        underservedByDistrict = underserved
        rescore()
    }

    private func rescore() {
        blocks = engine.blocks(weights: weights)
        blockIndex = Dictionary(uniqueKeysWithValues: blocks.enumerated().map { ($1.id, $0) })
        let excluded = Set(excludedBlocks.keys)
        spots = engine.shortlist(from: blocks, weights: weights, excluding: excluded)
        var levels: [Int: Confidence] = [:]
        for spot in spots {
            levels[spot.id] = engine.confidence(for: spot.block, weights: weights, evidence: evidence(for: spot.id))
        }
        confidences = levels

        // Coarse cells for the whole-territory view: the best block in each 3×3 group.
        var groups: [Int: Block] = [:]
        for block in blocks where block.score >= SiteEngine.minimumDrawnScore {
            let (row, col) = SiteEngine.Grid.rowColumn(of: block.id)
            let key = (row / 3) * SiteEngine.Grid.columns + (col / 3)
            if block.score > (groups[key]?.score ?? -1) { groups[key] = block }
        }
        coarseCells = groups.map { key, best in
            let origin = (key / SiteEngine.Grid.columns) * 3 * SiteEngine.Grid.columns + (key % SiteEngine.Grid.columns) * 3
            return DrawCell(id: "c\(key)", blockID: best.id, corners: SiteEngine.Grid.corners(of: origin, span: 3),
                            score: best.score)
        }

        let best = engine.bestBlocks(from: blocks, excluding: excluded)
        districtRows = AreaData.districts.map { district in
            let block = best[district.index]
            return DistrictRow(district: district, best: block, bestSpot: block.flatMap { spot(forBlock: $0.id) },
                               mappedStores: engine.mappedStores[district.index],
                               expectedStores: engine.expectedStores[district.index],
                               underserved: underservedByDistrict.indices.contains(district.index)
                                   ? underservedByDistrict[district.index] : 0)
        }
        .sorted { ($0.best?.netOrders ?? 0) > ($1.best?.netOrders ?? 0) }
        scoreVersion += 1
    }

    // MARK: Persistence

    private struct SavedState: Codable {
        var weights: Weights
        var pilotRounds: [PilotRound]
        var appliedEdits: [AppliedEdit]
        var reports: [Report]
        var decisions: [Int: SpotDecision]
        var recentSearches: [SearchResult]
    }

    private func save() {
        guard persists else { return }
        let state = SavedState(weights: weights, pilotRounds: pilotRounds, appliedEdits: appliedEdits, reports: reports,
                               decisions: decisions, recentSearches: recentSearches)
        if let encoded = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(encoded, forKey: storageKey)
        }
    }

    /// Returns false on first launch, when there's nothing saved yet.
    private func restore() -> Bool {
        guard let saved = UserDefaults.standard.data(forKey: storageKey),
              let state = try? JSONDecoder().decode(SavedState.self, from: saved) else { return false }
        weights = state.weights
        pilotRounds = state.pilotRounds
        appliedEdits = state.appliedEdits
        reports = state.reports
        decisions = state.decisions
        recentSearches = state.recentSearches
        return true
    }

    static func clearSavedState() {
        UserDefaults.standard.removeObject(forKey: "siteFinder.state.v2")
    }
}

func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
