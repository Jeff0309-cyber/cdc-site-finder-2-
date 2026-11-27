import Foundation

// Exports what the web version shows (a separate repository, cdc-site-finder-web), computed by the app's
// own engine so both always agree.
//
//   xcrun swiftc -O -o /tmp/web_export tools/web_export/main.swift \
//     ios/CDCSiteFinder/Model/{HKData,Places,SiteEngine,Explain,Reports,SearchIndex,Routes}.swift
//   /tmp/web_export ios/CDCSiteFinder/Resources ../cdc-site-finder-web/data/sitefinder.json

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    print("usage: web_export <folder with hk_places.json and hk_cells.json> <output.json>")
    exit(1)
}
HKData.directory = URL(fileURLWithPath: arguments[1])

let engine = SiteEngine()
let weights = Weights.starting
let blocks = engine.blocks(weights: weights)
let spots = engine.shortlist(from: blocks, weights: weights)
let districts = AreaData.districts

func round1(_ value: Double) -> Double { (value * 10).rounded() / 10 }
func round5(_ value: Double) -> Double { (value * 100_000).rounded() / 100_000 }

// MARK: How often each spot stays on top when the weights are uncertain

/// SplitMix64, so the published numbers are the same every time the export runs.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

let runs = 1000
var generator = SeededGenerator(state: 26210)
var firsts: [Int: Int] = [:]
var topThrees: [Int: Int] = [:]
for _ in 0..<runs {
    var w = weights
    for feature in Feature.allCases {
        w[feature] = weights[feature] * Double.random(in: 0.7...1.3, using: &generator)
    }
    let scale = weights.total / w.total
    for feature in Feature.allCases { w[feature] *= scale }
    let ranked = engine.shortlist(from: engine.blocks(weights: w), weights: w)
    if let first = ranked.first { firsts[first.id, default: 0] += 1 }
    for spot in ranked.prefix(3) { topThrees[spot.id, default: 0] += 1 }
}

// MARK: Spots

let spotRows: [[String: Any]] = spots.map { spot in
    let block = spot.block
    let confidence = engine.confidence(for: block, weights: weights, evidence: nil)
    let directions = Wayfinding.describe(block.center, data: engine.data)
    let district = districts[block.district]
    var row: [String: Any] = [
        "letter": spot.letter,
        "rank": spot.rank,
        "id": block.id,
        "lat": round5(block.center.latitude),
        "lon": round5(block.center.longitude),
        "kind": spot.kind.rawValue,
        "format": spot.format.rawValue,
        "formatDetail": spot.format.detail,
        "score": block.score,
        "netOrders": round1(block.netOrders),
        "low": round1(confidence.low),
        "high": round1(confidence.high),
        "range": confidence.rangeText,
        "confidence": confidence.level.title,
        "confidenceReason": confidence.reason,
        "catchment": Int(block.catchment.rounded()),
        "storeName": block.nearestStore.name,
        "storeDistance": Int(block.storeDistance.rounded()),
        "takenFromCDC": Int((block.cannibalisation * 100).rounded()),
        "district": district.name,
        "districtZH": district.nameZH,
        "short": directions.short,
        "english": directions.english,
        "chinese": directions.chinese,
        "why": Explain.why(block, weights: weights, data: engine.data, rank: spot.rank),
        "orders": [
            "lunch": round1(block.orders.lunch),
            "afterSchool": round1(block.orders.afterSchool),
            "evening": round1(block.orders.evening),
        ],
        "features": Feature.allCases.map { feature -> [String: Any] in
            [
                "title": feature.title,
                "short": feature.shortTitle,
                "value": round1((block.features[feature] ?? 0) * 100) / 100,
                "weight": weights[feature],
                "penalty": feature.isPenalty,
            ]
        },
        "firstShare": Double(firsts[block.id] ?? 0) / Double(runs),
        "topThreeShare": Double(topThrees[block.id] ?? 0) / Double(runs),
    ]
    if let note = confidence.coverageNote { row["coverageNote"] = note }
    return row
}

// MARK: Districts, ranked by their best block (same rules as the app)

var underserved = Array(repeating: 0.0, count: districts.count)
let residents = Dictionary(uniqueKeysWithValues: AreaData.raster.map { ($0.id, $0.residents) })
for block in blocks where block.storeDistance > 400 && underserved.indices.contains(block.district) {
    underserved[block.district] += residents[block.id] ?? 0
}
let best = engine.bestBlocks(from: blocks)
let districtRows: [[String: Any]] = districts.compactMap { district -> (Double, [String: Any])? in
    guard let block = best[district.index] else { return nil }
    let spot = spots.first { $0.id == block.id }
    var row: [String: Any] = [
        "name": district.name,
        "zh": district.nameZH,
        "population": district.population,
        "underserved": Int(underserved[district.index].rounded()),
        "mapped": engine.mappedStores[district.index],
        "expected": round1(engine.expectedStores[district.index]),
        "score": block.score,
        "netOrders": round1(block.netOrders),
        "short": Wayfinding.describe(block.center, data: engine.data).short,
        "lat": round5(block.center.latitude),
        "lon": round5(block.center.longitude),
    ]
    if let spot { row["spot"] = spot.letter }
    return (block.netOrders, row)
}
.sorted { $0.0 > $1.0 }
.map(\.1)

// MARK: Map layers

let drawn = blocks.filter { $0.score >= SiteEngine.minimumDrawnScore }.map { [$0.id, $0.score] }
let stores = engine.data.stores.map { store -> [Any] in
    [round5(store.coordinate.latitude), round5(store.coordinate.longitude), store.name, store.nameZH]
}
let grid = HKData.cells.grid

let formatter = DateFormatter()
formatter.dateFormat = "d MMM yyyy"
formatter.locale = Locale(identifier: "en_GB")

let output: [String: Any] = [
    "generated": formatter.string(from: Date()),
    "grid": ["minLat": grid.minLat, "minLon": grid.minLon, "latStep": grid.latStep, "lonStep": grid.lonStep,
             "rows": grid.rows, "columns": grid.columns],
    "blockCount": blocks.count,
    "storesMapped": engine.data.stores.count,
    "storesEstimated": AreaData.estimatedStoreTotal,
    "robustRuns": runs,
    "spots": spotRows,
    "districts": districtRows,
    "blocks": drawn,
    "stores": stores,
]

let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
try data.write(to: URL(fileURLWithPath: arguments[2]))
print("wrote \(arguments[2]): \(spotRows.count) spots, \(districtRows.count) districts, \(drawn.count) blocks, "
      + "\(stores.count) stores, \(data.count / 1024) KB")
for spot in spots {
    print("  \(spot.letter) #1 in \(Int((100 * Double(firsts[spot.id] ?? 0) / Double(runs)).rounded()))%, top 3 in "
          + "\(Int((100 * Double(topThrees[spot.id] ?? 0) / Double(runs)).rounded()))%  \(districts[spot.block.district].name)")
}
