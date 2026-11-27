import Foundation

// Prints the app engine's answers as JSON, so tools/web_parity/compare.py can check the website's
// JavaScript engine (docs/js/engine.js) gives the same ones. See tools/web_parity/README.md.

HKData.directory = URL(fileURLWithPath: CommandLine.arguments[1])
let engine = SiteEngine()
let data = engine.data
let w = Weights.starting
let blocks = engine.blocks(weights: w)
let spots = engine.shortlist(from: blocks, weights: w)

func r6(_ x: Double) -> Double { (x * 1_000_000).rounded() / 1_000_000 }
func weightsDict(_ w: Weights) -> [String: Double] {
    Dictionary(uniqueKeysWithValues: Feature.allCases.map { ($0.rawValue, r6(w[$0])) })
}

var out: [String: Any] = [:]
out["blockCount"] = blocks.count
out["drawn"] = blocks.filter { $0.score >= SiteEngine.minimumDrawnScore }.count
out["scoreSum"] = blocks.reduce(0) { $0 + $1.score }
out["netSum"] = r6(blocks.reduce(0) { $0 + $1.netOrders } / 1000)
out["offices"] = data.offices.prefix(5).map(\.name)
out["officeCount"] = data.offices.count
out["districtCenters"] = AreaData.districts.prefix(4).map { [r6($0.center.latitude), r6($0.center.longitude)] }

out["spots"] = spots.map { spot -> [String: Any] in
    let b = spot.block
    let c = engine.confidence(for: b, weights: w, evidence: nil)
    let d = Wayfinding.describe(b.center, data: data)
    return [
        "letter": spot.letter, "id": b.id, "score": b.score, "net": r6(b.netOrders), "kind": spot.kind.rawValue,
        "format": spot.format.rawValue, "level": c.level.title, "range": c.rangeText, "sensitiveTo": c.sensitiveTo.rawValue,
        "coverageNote": c.coverageNote ?? "", "english": d.english, "chinese": d.chinese, "short": d.short,
        "why": Explain.why(b, weights: w, data: data, rank: spot.rank), "landmark": spot.landmark?.name ?? "",
        "store": b.nearestStore.name, "storeDistance": Geo.formatDistance(b.storeDistance),
        "lunch": r6(b.orders.lunch), "afterSchool": r6(b.orders.afterSchool), "evening": r6(b.orders.evening),
    ]
}

let best = engine.bestBlocks(from: blocks)
out["districtBest"] = AreaData.districts.map { d -> [Any] in
    guard let b = best[d.index] else { return [d.name, -1, 0] }
    return [d.name, b.id, r6(b.netOrders)]
}
out["mappedStores"] = engine.mappedStores

let blockByID = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
let eleventh = blocks.filter { $0.storeDistance >= SiteEngine.minimumStoreGap }.sorted { $0.netOrders > $1.netOrders }[10]
let nearStore = blocks.first { $0.storeDistance < 200 && $0.score > 40 }!
out["exclusion"] = [eleventh, nearStore].map { engine.exclusionReason(for: $0, spots: spots, excluded: [:]) }
out["blockWhy"] = [eleventh, nearStore].map { Explain.why($0, weights: w, data: data, rank: nil) }
out["tradeOffs"] = spots.dropFirst().prefix(2).map { Explain.tradeOffs($0, against: spots[0], weights: w) }

let (round1, learned) = engine.runPilot(round: 1, weights: w, spots: Array(spots.prefix(3)))
out["pilot"] = ["errorBefore": r6(round1.errorBefore), "errorAfter": r6(round1.errorAfter),
                "weightsAfter": weightsDict(learned),
                "results": round1.results.map { [$0.letter, r6($0.predicted), r6($0.actual)] }]
let afterBlocks = engine.blocks(weights: learned)
out["afterPilotSpots"] = engine.shortlist(from: afterBlocks, weights: learned).map { [$0.letter, $0.id, r6($0.block.netOrders)] }

let bench = SearchBenchmark.run(spots: spots, data: data)
out["search"] = ["passed": bench.passed, "total": bench.total,
                 "first": SearchBenchmark.cases.map { SearchIndex.results(for: $0.query, spots: spots, data: data, limit: 3).map(\.title) }]

let seeds = ReportChecks.seeds(data: data, block: { blockByID[$0] }, spots: spots)
out["seeds"] = seeds.map { report -> [String] in
    let target: String = switch report.target {
    case .place(let id): "place:\(id)"
    case .block(let id): "block:\(id)"
    }
    return [report.kind.rawValue, report.role.rawValue, target, report.check.verdict.rawValue, report.check.detail]
}

// An approved closure: the oldest rival removed, then the area re-scored.
let oldest = data.rivals.max { $0.confirmedDaysAgo < $1.confirmedDaysAgo }!
let edited = SiteEngine(data: data.applying([.removePlace(id: oldest.id)]))
let editedBlocks = edited.blocks(weights: w)
out["afterClosure"] = edited.shortlist(from: editedBlocks, weights: w).map { [$0.letter, $0.id, r6($0.block.netOrders)] }
out["afterClosureNetSum"] = r6(editedBlocks.reduce(0) { $0 + $1.netOrders } / 1000)

let json = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys, .prettyPrinted])
print(String(data: json, encoding: .utf8)!)
