import Foundation

/// The six inputs on the "How the AI picks the spots" slide, measured with open data.
enum Feature: String, CaseIterable, Identifiable, Codable {
    case appOrders, schools, offices, rivals, footfall, rent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appOrders: "Homes with no CDC nearby"
        case .schools: "Schools and campuses"
        case .offices: "Offices and young workers"
        case .rivals: "Rivals nearby"
        case .footfall: "Footfall and MTR exits"
        case .rent: "Rents (shop density)"
        }
    }

    var shortTitle: String {
        switch self {
        case .appOrders: "Homes"
        case .schools: "Schools"
        case .offices: "Offices"
        case .rivals: "Rivals"
        case .footfall: "Footfall"
        case .rent: "Rent"
        }
    }

    var source: String {
        switch self {
        case .appOrders: "Where people live: OpenStreetMap homes scaled to 2021 Census district totals. Stands in for Club 100 and eatCDC orders"
        case .schools: "Schools and university campuses from OpenStreetMap"
        case .offices: "Office and commercial buildings from OpenStreetMap"
        case .rivals: "Fairwood, Maxim's MX, Tai Hing and McDonald's outlets from OpenStreetMap"
        case .footfall: "MTR stations from OpenStreetMap"
        case .rent: "Shop density from OpenStreetMap, standing in for ground-floor rents"
        }
    }

    /// When the data behind the input was last refreshed.
    var updated: String {
        switch self {
        case .appOrders: "Homes downloaded 27 Nov 2026 · Census 2021"
        case .rivals: "Downloaded 27 Nov 2026 · outlets last checked at different times"
        default: "Downloaded 27 Nov 2026"
        }
    }

    var symbol: String {
        switch self {
        case .appOrders: "house.fill"
        case .schools: "graduationcap.fill"
        case .offices: "building.2.fill"
        case .rivals: "storefront.fill"
        case .footfall: "tram.fill"
        case .rent: "key.fill"
        }
    }

    /// Rivals and rent lower a block's score; the other four raise it.
    var isPenalty: Bool { self == .rivals || self == .rent }
}

struct Weights: Equatable, Codable {
    var values: [Feature: Double]

    subscript(_ feature: Feature) -> Double {
        get { values[feature] ?? 0 }
        set { values[feature] = newValue }
    }

    var total: Double { Feature.allCases.reduce(0) { $0 + self[$1] } }

    /// The model's starting guess, before any pilot data.
    static let starting = Weights(values: [
        .appOrders: 0.30, .schools: 0.20, .offices: 0.20, .rivals: 0.08, .footfall: 0.20, .rent: 0.06,
    ])

    /// What the real world rewards in this simulation. The model never sees these numbers; it only sees
    /// locker sales generated from them, and has to learn its way towards them.
    static let hiddenTruth = Weights(values: [
        .appOrders: 0.34, .schools: 0.30, .offices: 0.10, .rivals: 0.12, .footfall: 0.16, .rent: 0.05,
    ])
}

struct Orders: Equatable, Codable {
    var lunch: Double
    var afterSchool: Double
    var evening: Double

    var total: Double { lunch + afterSchool + evening }

    func scaled(by factor: Double) -> Orders {
        Orders(lunch: lunch * factor, afterSchool: afterSchool * factor, evening: evening * factor)
    }
}

/// One street block of the grid with everything the model predicts for it.
struct Block: Identifiable, Equatable {
    let id: Int
    let center: Coordinate
    /// Inputs scaled to 0...1 against the original data.
    let features: [Feature: Double]
    let nearestStore: Place
    let storeDistance: Double
    let district: Int
    /// People living within about a 5-minute walk.
    let catchment: Double

    var score: Int
    var orders: Orders
    /// Share of this block's orders that would otherwise have gone to the nearest CDC.
    var cannibalisation: Double

    var corners: [Coordinate] { SiteEngine.Grid.corners(of: id) }

    /// New orders a day once sales moved from the nearest CDC are taken out.
    var netOrders: Double { orders.total * (1 - cannibalisation) }

    func contribution(_ feature: Feature, weights: Weights) -> Double {
        let value = weights[feature] * (features[feature] ?? 0)
        return feature.isPenalty ? -value : value
    }

    static func == (lhs: Block, rhs: Block) -> Bool {
        lhs.id == rhs.id && lhs.score == rhs.score && lhs.orders == rhs.orders
    }
}

enum SpotKind: String, Codable {
    case schoolCluster = "School cluster"
    case university = "University campus"
    case officeHub = "Office hub"
    case transitHub = "Transit hub"
    case housingArea = "Housing area"
}

enum StartFormat: String, Codable {
    case locker = "Locker"
    case kiosk = "Pop-up kiosk"
    case store = "Full store"

    var detail: String {
        switch self {
        case .locker: "A 40-slot pickup locker refilled from the nearest kitchen three times a day. Cheapest way to test demand."
        case .kiosk: "A small counter with a reduced menu. Needs a shopfront and two staff at peak."
        case .store: "A full Café de Coral. Only worth it once lockers and kiosks prove steady demand."
        }
    }

    var symbol: String {
        switch self {
        case .locker: "square.grid.3x3.fill"
        case .kiosk: "takeoutbag.and.cup.and.straw.fill"
        case .store: "fork.knife"
        }
    }
}

/// A shortlisted block, with its rank letter.
struct Spot: Identifiable, Equatable {
    var id: Int { block.id }
    let letter: String
    let rank: Int
    let block: Block
    let kind: SpotKind
    let landmark: Place?
    let format: StartFormat

    var title: String { "Spot \(letter) · \(kind.rawValue)" }
}

struct PilotResult: Identifiable, Equatable, Codable {
    var id: Int { blockID }
    let blockID: Int
    let letter: String
    let kind: SpotKind
    let predicted: Double
    let actual: Double

    var error: Double { abs(actual - predicted) / actual }
}

struct PilotRound: Identifiable, Equatable, Codable {
    let id: Int
    let results: [PilotResult]
    let weightsBefore: Weights
    let weightsAfter: Weights
    /// Average prediction error on this round's spots, before and after the model learned from them.
    let errorBefore: Double
    let errorAfter: Double
}

/// A pilot that tested this exact block.
struct PilotEvidence: Equatable {
    let round: Int
    let result: PilotResult
}

/// How sure the model is about a block's prediction: re-scored with every weight nudged up and
/// down by 30%, then marked down where the store map is thin. Shown as a level and a range.
struct Confidence: Equatable {
    enum Level: Int, Comparable {
        case low, medium, high

        static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }

        var title: String {
            switch self {
            case .low: "Low"
            case .medium: "Medium"
            case .high: "High"
            }
        }

        /// Half-width of the range shown around the prediction.
        var margin: Double {
            switch self {
            case .low: 0.28
            case .medium: 0.18
            case .high: 0.10
            }
        }
    }

    /// Re-scoring with each weight 30% higher and lower moves the prediction by at least this share.
    static let sensitiveSpread = 0.12

    let level: Level
    let low: Double
    let high: Double
    /// The input whose weight would move this prediction most if it turned out to be wrong.
    let sensitiveTo: Feature
    let evidence: PilotEvidence?
    /// Set when few of the district's CDC stores are on the map, so "no CDC nearby" may be wrong.
    let coverageNote: String?

    var rangeText: String { "\(Int(low.rounded()))–\(Int(high.rounded()))" }

    var reason: String {
        var text = "Moves most if the \(sensitiveTo.shortTitle.lowercased()) weight is off."
        if let evidence {
            text += " Tested in pilot round \(evidence.round): \(Int(evidence.result.predicted.rounded())) predicted,"
                + " \(Int(evidence.result.actual.rounded())) actual."
        } else {
            text += " Not piloted yet, so the range is wide."
        }
        if let coverageNote { text += " " + coverageNote }
        return text
    }
}

/// Scores every street block in Hong Kong. Pure and deterministic, so it's easy to test.
struct SiteEngine {
    enum Grid {
        static let minLat = HKData.cells.grid.minLat
        static let minLon = HKData.cells.grid.minLon
        /// About 280 m by 280 m.
        static let latStep = HKData.cells.grid.latStep
        static let lonStep = HKData.cells.grid.lonStep
        static let rows = HKData.cells.grid.rows
        static let columns = HKData.cells.grid.columns
        static let cellHeight = latStep * 110_540
        static let cellWidth = lonStep * cos(22.35 * .pi / 180) * 111_320

        static func id(at coordinate: Coordinate) -> Int? {
            let row = Int(floor((coordinate.latitude - minLat) / latStep))
            let col = Int(floor((coordinate.longitude - minLon) / lonStep))
            guard (0..<rows).contains(row), (0..<columns).contains(col) else { return nil }
            return row * columns + col
        }

        static func rowColumn(of id: Int) -> (row: Int, column: Int) { (id / columns, id % columns) }

        static func center(of id: Int) -> Coordinate {
            let (row, col) = rowColumn(of: id)
            return Coordinate(minLat + (Double(row) + 0.5) * latStep, minLon + (Double(col) + 0.5) * lonStep)
        }

        static func corners(of id: Int, span: Int = 1) -> [Coordinate] {
            let (row, col) = rowColumn(of: id)
            let lat = minLat + Double(row) * latStep
            let lon = minLon + Double(col) * lonStep
            let height = latStep * Double(span)
            let width = lonStep * Double(span)
            return [Coordinate(lat, lon), Coordinate(lat, lon + width), Coordinate(lat + height, lon + width),
                    Coordinate(lat + height, lon)]
        }
    }

    /// Blocks below this score aren't drawn, so empty land and water stay clear.
    static let minimumDrawnScore = 22
    static let minimumStoreGap = 320.0
    static let minimumSpotSpacing = 650.0
    static let shortlistCount = 10
    /// Keeps the shortlist spread across Hong Kong instead of piling into one district.
    static let maxSpotsPerDistrict = 2

    static let noStore = Place(id: "none", name: "No CDC store", nameZH: "", kind: .cdcStore,
                               coordinate: Coordinate(0, 0), detail: "")

    private struct Cell {
        let id: Int
        let center: Coordinate
        let features: [Feature: Double]
        let nearestStore: Place
        let storeDistance: Double
        let district: Int
        let catchment: Double
    }

    let data: AreaDataset
    private let cells: [Cell]
    private let indexByID: [Int: Int]
    /// Mapped stores per district, and how many a district of its size would usually have.
    let mappedStores: [Int]
    let expectedStores: [Double]

    var blockCount: Int { cells.count }

    /// Where each input reaches 1.0, as a percentile of the original data. High enough that the
    /// densest places in Hong Kong stay distinguishable instead of all hitting the ceiling.
    static let scalePercentile: [Feature: Double] = [
        .appOrders: 0.995, .schools: 0.99, .offices: 0.99, .rivals: 0.99, .footfall: 0.97, .rent: 0.99,
    ]

    /// Inputs are scaled against the original data, not the edited data, so an approved edit
    /// (a rival closing, say) only changes the blocks around it.
    private static let referenceScale: [Feature: Double] = {
        var values: [Feature: [Double]] = [:]
        for cell in rawCells(for: .base) {
            for (feature, value) in cell.features where value > 0 { values[feature, default: []].append(value) }
        }
        var scale: [Feature: Double] = [:]
        for (feature, list) in values {
            let sorted = list.sorted()
            let percentile = scalePercentile[feature] ?? 0.97
            scale[feature] = sorted[min(sorted.count - 1, Int(Double(sorted.count) * percentile))]
        }
        return scale
    }()

    init(data: AreaDataset = .base) {
        self.data = data
        let scale = Self.referenceScale
        cells = Self.rawCells(for: data).map { raw in
            var scaled: [Feature: Double] = [:]
            for (feature, value) in raw.features {
                let top = scale[feature] ?? 0
                scaled[feature] = top > 0 ? min(1, value / top) : 0
            }
            return Cell(id: raw.id, center: raw.center, features: scaled, nearestStore: raw.nearestStore,
                        storeDistance: raw.storeDistance, district: raw.district, catchment: raw.catchment)
        }
        indexByID = Dictionary(uniqueKeysWithValues: cells.enumerated().map { ($1.id, $0) })

        let districts = AreaData.districts
        let totalPopulation = Double(districts.reduce(0) { $0 + $1.population })
        var mapped = Array(repeating: 0, count: districts.count)
        for store in data.stores where districts.indices.contains(store.district) { mapped[store.district] += 1 }
        mappedStores = mapped
        expectedStores = districts.map { Double(AreaData.estimatedStoreTotal) * Double($0.population) / totalPopulation }
    }

    // MARK: Inputs

    private struct RawCell {
        let id: Int
        let center: Coordinate
        let features: [Feature: Double]
        let nearestStore: Place
        let storeDistance: Double
        let district: Int
        let catchment: Double
    }

    /// Places grouped by grid block, so each block only looks at its neighbours.
    private struct PlaceBuckets {
        private var buckets: [Int: [Place]] = [:]

        init(_ places: [Place]) {
            for place in places {
                if let id = Grid.id(at: place.coordinate) { buckets[id, default: []].append(place) }
            }
        }

        func near(row: Int, column: Int, radius: Int) -> [Place] {
            var found: [Place] = []
            for r in max(0, row - radius)...min(Grid.rows - 1, row + radius) {
                for c in max(0, column - radius)...min(Grid.columns - 1, column + radius) {
                    if let list = buckets[r * Grid.columns + c] { found += list }
                }
            }
            return found
        }
    }

    private static func falloff(_ distance: Double, radius: Double) -> Double {
        exp(-(distance * distance) / (radius * radius))
    }

    private static func rawCells(for data: AreaDataset) -> [RawCell] {
        let raster = AreaData.raster
        var rasterByID: [Int: RasterCell] = [:]
        for cell in raster { rasterByID[cell.id] = cell }
        let schools = PlaceBuckets(data.schools)
        let universities = PlaceBuckets(data.universities)
        let rivals = PlaceBuckets(data.rivals)
        let stations = PlaceBuckets(data.stations)

        return raster.map { cell in
            let (row, col) = Grid.rowColumn(of: cell.id)
            let center = Grid.center(of: cell.id)

            // Homes, offices and shops spread a little into neighbouring blocks.
            var residents = 0.0, office = 0.0, shops = 0.0, catchment = 0.0
            for dr in -2...2 {
                for dc in -2...2 {
                    let r = row + dr, c = col + dc
                    guard (0..<Grid.rows).contains(r), (0..<Grid.columns).contains(c),
                          let other = rasterByID[r * Grid.columns + c] else { continue }
                    let distance = hypot(Double(dr) * Grid.cellHeight, Double(dc) * Grid.cellWidth)
                    residents += other.residents * falloff(distance, radius: 350)
                    office += other.office * falloff(distance, radius: 420)
                    shops += other.shops * falloff(distance, radius: 380)
                    if distance <= 420 { catchment += other.residents }
                }
            }

            func sum(_ buckets: PlaceBuckets, radius: Double, reach: Int, weight: Double = 1) -> Double {
                buckets.near(row: row, column: col, radius: reach)
                    .reduce(0) { $0 + weight * falloff(Geo.meters(center, $1.coordinate), radius: radius) }
            }

            let nearest = nearest(data.stores, to: center)
            let storeDistance = nearest?.distance ?? .infinity
            // Homes only count as unserved demand when there's no CDC within easy walking distance.
            let unserved = 1 - exp(-storeDistance / 380)

            return RawCell(
                id: cell.id, center: center,
                features: [
                    .appOrders: residents * unserved,
                    .schools: sum(schools, radius: 420, reach: 4) + sum(universities, radius: 480, reach: 4, weight: 1.8),
                    .offices: office,
                    .rivals: sum(rivals, radius: 260, reach: 3),
                    .footfall: sum(stations, radius: 300, reach: 3),
                    .rent: shops,
                ],
                nearestStore: nearest?.place ?? noStore, storeDistance: storeDistance,
                district: cell.district, catchment: catchment)
        }
    }

    static func nearest(_ places: [Place], to point: Coordinate) -> (place: Place, distance: Double)? {
        var best: (place: Place, distance: Double)?
        for place in places {
            let distance = Geo.meters(point, place.coordinate)
            if distance < (best?.distance ?? .infinity) { best = (place, distance) }
        }
        return best
    }

    // MARK: Scoring

    func blocks(weights: Weights) -> [Block] {
        cells.map { makeBlock($0, weights) }
    }

    func index(of id: Int) -> Int? { indexByID[id] }

    /// One block, without scoring the whole grid. Used for sensitivity checks and pilots.
    func block(_ id: Int, weights: Weights) -> Block {
        guard let index = indexByID[id] else { preconditionFailure("No block \(id) in the dataset") }
        return makeBlock(cells[index], weights)
    }

    private func makeBlock(_ cell: Cell, _ weights: Weights) -> Block {
        let positiveTotal = Feature.allCases.filter { !$0.isPenalty }.reduce(0) { $0 + weights[$1] }
        let scale = max(positiveTotal, 0.01) * 0.62
        var raw = 0.0
        for feature in Feature.allCases {
            let value = weights[feature] * (cell.features[feature] ?? 0)
            raw += feature.isPenalty ? -value : value
        }
        // Soft ceiling: strong blocks approach 100 without piling up at it.
        let exactScore = 100 * (1 - exp(-1.9 * max(0, raw / scale)))
        let cannibalisation = cell.storeDistance.isFinite ? 0.32 * exp(-cell.storeDistance / 360) : 0
        // Orders use the exact score; only the displayed score is rounded. Otherwise a small weight change
        // from a pilot could leave every prediction exactly where it was.
        return Block(id: cell.id, center: cell.center, features: cell.features, nearestStore: cell.nearestStore,
                     storeDistance: cell.storeDistance, district: cell.district, catchment: cell.catchment,
                     score: Int(exactScore.rounded()), orders: Self.orders(score: exactScore, features: cell.features),
                     cannibalisation: cannibalisation)
    }

    /// Expected orders a day at a small format. Grows faster than linearly with score, split by time of day.
    static func orders(score: Double, features: [Feature: Double]) -> Orders {
        let total = 0.0565 * pow(score, 1.6)
        let f = { (feature: Feature) in features[feature] ?? 0 }
        let lunch = 0.30 + 0.55 * f(.offices) + 0.20 * f(.footfall)
        let afterSchool = 0.12 + 0.75 * f(.schools)
        let evening = 0.25 + 0.40 * f(.appOrders) + 0.25 * f(.footfall)
        let share = lunch + afterSchool + evening
        return Orders(lunch: total * lunch / share, afterSchool: total * afterSchool / share,
                      evening: total * evening / share)
    }

    // MARK: Store coverage

    /// Share of a district's likely CDC stores that are on the map (capped at 1).
    func coverage(of district: Int) -> Double {
        guard expectedStores.indices.contains(district), expectedStores[district] > 0 else { return 1 }
        return min(1, Double(mappedStores[district]) / expectedStores[district])
    }

    func coverageNote(for district: Int) -> String? {
        guard coverage(of: district) < 0.6 else { return nil }
        let name = AreaData.districts[district].name
        return "Only \(mappedStores[district]) of about \(Int(expectedStores[district].rounded())) CDC stores in \(name) are mapped, so check for a nearby branch before deciding."
    }

    // MARK: Confidence

    func confidence(for block: Block, weights: Weights, evidence: PilotEvidence?) -> Confidence {
        let base = block.netOrders
        var values = [base]
        var sensitiveTo = Feature.appOrders
        var biggestSwing = -1.0
        for feature in Feature.allCases {
            var swing = 0.0
            for factor in [0.7, 1.3] {
                var nudged = weights
                nudged[feature] *= factor
                let value = self.block(block.id, weights: nudged).netOrders
                values.append(value)
                swing = max(swing, abs(value - base))
            }
            if swing > biggestSwing {
                biggestSwing = swing
                sensitiveTo = feature
            }
        }
        let spread = ((values.max() ?? base) - (values.min() ?? base)) / max(base, 1)
        // Before a pilot the model is an unvalidated guess, so it never claims High.
        // A prediction that swings a lot when one weight changes drops a level, and so does a
        // district where most CDC stores are missing from the map.
        let sensitive = spread >= Confidence.sensitiveSpread
        var level: Confidence.Level = evidence != nil ? (sensitive ? .medium : .high) : (sensitive ? .low : .medium)
        let note = evidence == nil ? coverageNote(for: block.district) : nil
        if note != nil, level > .low, let lower = Confidence.Level(rawValue: level.rawValue - 1) { level = lower }
        return Confidence(level: level, low: base * (1 - level.margin), high: base * (1 + level.margin),
                          sensitiveTo: sensitiveTo, evidence: evidence, coverageNote: note)
    }

    // MARK: Shortlist

    private func eligible(_ block: Block, excluding excluded: Set<Int>) -> Bool {
        block.storeDistance >= Self.minimumStoreGap && !excluded.contains(block.id)
    }

    func shortlist(from blocks: [Block], weights: Weights, excluding excluded: Set<Int> = [],
                   count: Int = shortlistCount) -> [Spot] {
        var picked: [Block] = []
        var perDistrict: [Int: Int] = [:]
        let candidates = blocks.filter { eligible($0, excluding: excluded) }.sorted { $0.netOrders > $1.netOrders }
        for block in candidates where picked.count < count {
            guard perDistrict[block.district, default: 0] < Self.maxSpotsPerDistrict else { continue }
            guard picked.allSatisfy({ Geo.meters($0.center, block.center) >= Self.minimumSpotSpacing }) else { continue }
            picked.append(block)
            perDistrict[block.district, default: 0] += 1
        }
        let letters = (0..<26).map { String(UnicodeScalar(UInt8(65 + $0))) }
        return picked.enumerated().map { index, block in
            let kind = kind(of: block, weights: weights)
            return Spot(letter: letters[index], rank: index + 1, block: block, kind: kind,
                        landmark: landmark(for: block, kind: kind), format: Self.format(for: block))
        }
    }

    /// The best block in each district, by new orders a day.
    func bestBlocks(from blocks: [Block], excluding excluded: Set<Int> = []) -> [Int: Block] {
        var best: [Int: Block] = [:]
        for block in blocks where eligible(block, excluding: excluded) {
            if block.netOrders > (best[block.district]?.netOrders ?? -1) { best[block.district] = block }
        }
        return best
    }

    /// Why a block that isn't shortlisted was left out.
    func exclusionReason(for block: Block, spots: [Spot], excluded: [Int: String]) -> String {
        if let reason = excluded[block.id] {
            return "Taken off the shortlist: \(reason)."
        }
        if block.storeDistance < Self.minimumStoreGap {
            return "Within \(Int(Self.minimumStoreGap)) m of the \(block.nearestStore.name) CDC, which already serves it."
        }
        if let near = spots.first(where: { Geo.meters($0.block.center, block.center) < Self.minimumSpotSpacing }) {
            return "Too close to Spot \(near.letter). Two sites this near would split the same customers."
        }
        let sameDistrict = spots.filter { $0.block.district == block.district }
        if sameDistrict.count >= Self.maxSpotsPerDistrict,
           let weakest = sameDistrict.last, block.netOrders > (spots.last?.block.netOrders ?? 0) {
            let letters = sameDistrict.map(\.letter).joined(separator: " and ")
            return "Spots \(letters) already cover \(AreaData.districts[block.district].name) (weakest: ~\(Int(weakest.block.netOrders.rounded())) a day). The shortlist keeps at most two per district so it spreads across Hong Kong."
        }
        return "Fewer expected new orders than the \(spots.count) shortlisted spots."
    }

    /// Named after the strongest local driver. Homes show up almost everywhere, so a spot is only
    /// called a housing area when schools, offices and footfall are all weak.
    func kind(of block: Block, weights: Weights) -> SpotKind {
        let drivers: [Feature] = [.schools, .offices, .footfall]
        let top = drivers.max { block.contribution($0, weights: weights) < block.contribution($1, weights: weights) }
        let strength = top.map { block.features[$0] ?? 0 } ?? 0
        guard strength >= 0.3 else { return .housingArea }
        switch top {
        case .schools:
            let university = Self.nearest(data.universities, to: block.center)
            return (university?.distance ?? .infinity) < 550 ? .university : .schoolCluster
        case .offices: return .officeHub
        case .footfall: return .transitHub
        default: return .housingArea
        }
    }

    func landmark(for block: Block, kind: SpotKind) -> Place? {
        let pool: [Place] = switch kind {
        case .university: data.universities
        case .schoolCluster: data.schools + data.universities
        case .officeHub: data.offices
        case .transitHub, .housingArea: data.stations
        }
        return Self.nearest(pool, to: block.center)?.place
    }

    static func format(for block: Block) -> StartFormat {
        switch block.netOrders {
        case ..<95: .locker
        case ..<170: .kiosk
        default: .store
        }
    }

    // MARK: Learning from pilots

    /// Daily locker sales the pilot "observes" at a block: generated from the hidden truth, plus a
    /// small fixed wobble per block so results never match a formula exactly.
    func observedOrders(at blockID: Int, round: Int) -> Double {
        let truth = block(blockID, weights: .hiddenTruth)
        let wobble = 1 + 0.05 * sin(Double(blockID) * 12.9898 + Double(round) * 78.233)
        return truth.netOrders * wobble
    }

    /// Runs a 4-week locker pilot at the given spots, then nudges each weight towards whatever
    /// explains the gap between predicted and actual sales.
    func runPilot(round: Int, weights: Weights, spots tested: [Spot]) -> (PilotRound, Weights) {
        let observed = tested.map { observedOrders(at: $0.block.id, round: round) }

        var updated = weights
        let learningRate = 0.9
        for _ in 0..<4 {
            var gradients: [Feature: Double] = [:]
            for (spot, actual) in zip(tested, observed) {
                let predicted = block(spot.block.id, weights: updated).netOrders
                let ratio = (actual - predicted) / max(predicted, 1)
                for feature in Feature.allCases {
                    gradients[feature, default: 0] += ratio * (spot.block.features[feature] ?? 0)
                }
            }
            for feature in Feature.allCases {
                let gradient = (gradients[feature] ?? 0) / Double(max(tested.count, 1))
                // Under-predicting where a feature is strong means it deserves more weight
                // (or, for a penalty, less).
                let step = feature.isPenalty ? -gradient : gradient
                updated[feature] = min(0.6, max(0.02, updated[feature] * exp(learningRate * step)))
            }
            // Keep the total fixed so the weights read as shares and don't drift upwards together.
            let scale = weights.total / max(updated.total, 0.01)
            for feature in Feature.allCases { updated[feature] *= scale }
        }

        let results = zip(tested, observed).map { spot, actual in
            PilotResult(blockID: spot.block.id, letter: spot.letter, kind: spot.kind,
                        predicted: block(spot.block.id, weights: weights).netOrders, actual: actual)
        }
        let errorBefore = results.map(\.error).reduce(0, +) / Double(max(results.count, 1))
        let errorAfter = zip(tested, observed)
            .map { abs($1 - block($0.block.id, weights: updated).netOrders) / $1 }
            .reduce(0, +) / Double(max(results.count, 1))

        return (PilotRound(id: round, results: results, weightsBefore: weights, weightsAfter: updated,
                           errorBefore: errorBefore, errorAfter: errorAfter), updated)
    }
}
