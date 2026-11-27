import XCTest
@testable import CDCSiteFinder

final class EngineTests: XCTestCase {
    private let engine = SiteEngine()

    func testBlockIDsRoundTripThroughTheGrid() {
        let blocks = engine.blocks(weights: .starting)
        XCTAssertEqual(blocks.count, engine.blockCount)
        XCTAssertGreaterThan(blocks.count, 5000, "The whole territory, not one district")
        for block in blocks {
            XCTAssertEqual(SiteEngine.Grid.id(at: block.center), block.id)
        }
        XCTAssertNil(SiteEngine.Grid.id(at: Coordinate(21.9, 114.0)), "Points outside Hong Kong have no block")
    }

    func testResidentsAddUpToTheCensus() {
        let total = AreaData.raster.reduce(0) { $0 + $1.residents }
        let census = Double(AreaData.districts.reduce(0) { $0 + $1.population })
        XCTAssertEqual(total, census, accuracy: census * 0.01, "Homes are scaled to the 2021 Census district totals")
    }

    func testScoresStayBetweenZeroAndOneHundred() {
        for block in engine.blocks(weights: .starting) {
            XCTAssertTrue((0...100).contains(block.score))
            XCTAssertGreaterThanOrEqual(block.netOrders, 0)
        }
    }

    func testShortlistSpreadsAcrossHongKongAndKeepsItsSpacing() {
        let spots = engine.shortlist(from: engine.blocks(weights: .starting), weights: .starting)
        XCTAssertEqual(spots.count, SiteEngine.shortlistCount)
        for spot in spots {
            XCTAssertGreaterThanOrEqual(spot.block.storeDistance, SiteEngine.minimumStoreGap)
        }
        for (i, a) in spots.enumerated() {
            for b in spots.dropFirst(i + 1) {
                XCTAssertGreaterThanOrEqual(Geo.meters(a.block.center, b.block.center), SiteEngine.minimumSpotSpacing)
            }
        }
        let perDistrict = Dictionary(grouping: spots, by: \.block.district)
        XCTAssertTrue(perDistrict.values.allSatisfy { $0.count <= SiteEngine.maxSpotsPerDistrict })
        XCTAssertGreaterThanOrEqual(perDistrict.count, 5, "Spots should cover several districts")
        XCTAssertEqual(spots.map(\.block.netOrders), spots.map(\.block.netOrders).sorted(by: >),
                       "Ranked by new orders, best first")
    }

    func testEveryDistrictHasABestBlock() {
        let best = engine.bestBlocks(from: engine.blocks(weights: .starting))
        XCTAssertEqual(best.count, AreaData.districts.count)
    }

    func testExcludedBlockLeavesTheShortlist() {
        let blocks = engine.blocks(weights: .starting)
        let before = engine.shortlist(from: blocks, weights: .starting)
        let after = engine.shortlist(from: blocks, weights: .starting, excluding: [before[0].id])
        XCTAssertFalse(after.contains { $0.id == before[0].id })
        XCTAssertEqual(after.count, before.count, "The next best block fills the gap")
    }

    func testPilotLearningReducesErrorAndKeepsTheWeightTotal() {
        let spots = engine.shortlist(from: engine.blocks(weights: .starting), weights: .starting)
        let (round, learned) = engine.runPilot(round: 1, weights: .starting, spots: Array(spots.prefix(3)))
        XCTAssertLessThan(round.errorAfter, round.errorBefore)
        XCTAssertEqual(learned.total, Weights.starting.total, accuracy: 1e-9)
    }

    func testConfidenceIsNeverHighBeforeAPilot() {
        let spots = engine.shortlist(from: engine.blocks(weights: .starting), weights: .starting)
        for spot in spots {
            let confidence = engine.confidence(for: spot.block, weights: .starting, evidence: nil)
            XCTAssertNotEqual(confidence.level, .high, "\(spot.title) claims High confidence without a pilot")
            XCTAssertLessThan(confidence.low, spot.block.netOrders)
            XCTAssertGreaterThan(confidence.high, spot.block.netOrders)
        }
    }

    func testThinStoreCoverageLowersConfidence() {
        for district in AreaData.districts.indices {
            let coverage = engine.coverage(of: district)
            XCTAssertTrue((0...1).contains(coverage))
            XCTAssertEqual(engine.coverageNote(for: district) != nil, coverage < 0.6)
        }
    }

    func testClosingARivalOnlyChangesNearbyBlocksAndOnlyUpwards() throws {
        let rival = try XCTUnwrap(AreaDataset.base.rivals.first)
        let before = engine.blocks(weights: .starting)
        let after = SiteEngine(data: AreaDataset.base.applying([.removePlace(id: rival.id)])).blocks(weights: .starting)
        let changed = zip(before, after).filter { $0.score != $1.score }
        for (old, new) in changed {
            XCTAssertLessThan(Geo.meters(old.center, rival.coordinate), 1200, "A closure far away shouldn't move this block")
            XCTAssertGreaterThan(new.score, old.score, "One rival fewer can only help")
        }
    }

    func testTheLastStoreCannotBeRemoved() {
        let edits = AreaDataset.base.stores.map { DataEdit.removePlace(id: $0.id) }
        XCTAssertEqual(AreaDataset.base.applying(edits).stores.count, 1)
    }

    func testDirectionsUseStationsInBothLanguages() {
        let nearMongKok = Coordinate(22.3205, 114.1700)
        let directions = Wayfinding.describe(nearMongKok, data: .base)
        XCTAssertTrue(directions.english.contains("station"), directions.english)
        XCTAssertTrue(directions.chinese.contains("站"), directions.chinese)
        XCTAssertNotNil(directions.walkMinutes)
    }

    func testCompassPoints() {
        XCTAssertEqual(Wayfinding.compass(0).english, "north")
        XCTAssertEqual(Wayfinding.compass(90).english, "east")
        XCTAssertEqual(Wayfinding.compass(225).english, "south-west")
        XCTAssertEqual(Wayfinding.compass(359).english, "north")
        XCTAssertEqual(Wayfinding.compass(45).chinese, "東北")
    }
}
