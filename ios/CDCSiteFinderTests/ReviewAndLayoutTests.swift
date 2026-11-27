import XCTest
@testable import CDCSiteFinder

final class PinLayoutTests: XCTestCase {
    func testVisiblePinsNeverOverlap() {
        var candidates: [PinLayout.Candidate] = []
        let kinds = PlaceKind.allCases
        for index in 0..<200 {
            // A deterministic scatter, dense enough to force collisions.
            let x = CGFloat((index * 37) % 390)
            let y = CGFloat((index * 53) % 600)
            candidates.append(PinLayout.Candidate(id: "p\(index)", kind: kinds[index % kinds.count], point: CGPoint(x: x, y: y)))
        }
        let reserved = [CGPoint(x: 100, y: 100), CGPoint(x: 130, y: 100)]
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 600)
        let result = PinLayout.visible(candidates, reserved: reserved, bounds: bounds)

        let shown = candidates.filter { result.visible.contains($0.id) && bounds.contains($0.point) }.map(\.point)
        for (i, a) in shown.enumerated() {
            for b in shown.dropFirst(i + 1) {
                XCTAssertGreaterThanOrEqual(hypot(a.x - b.x, a.y - b.y), PinLayout.spacing)
            }
            for r in reserved {
                XCTAssertGreaterThanOrEqual(hypot(a.x - r.x, a.y - r.y), PinLayout.spacing)
            }
        }
        XCTAssertGreaterThan(result.hiddenOnScreen, 0)
    }

    func testHigherPriorityPinWins() {
        let point = CGPoint(x: 50, y: 50)
        let result = PinLayout.visible([
            PinLayout.Candidate(id: "rival", kind: .rival, point: point),
            PinLayout.Candidate(id: "store", kind: .cdcStore, point: point),
        ], reserved: [], bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(result.visible, ["store"])
    }

    func testOverlappingSpotsFoldIntoTheBestRankedOne() {
        // Best first: 1 and 2 overlap (2 sits on 1's score label), 3 is far away.
        let spots: [(id: Int, point: CGPoint)] = [(1, CGPoint(x: 100, y: 100)), (2, CGPoint(x: 150, y: 110)),
                                                  (3, CGPoint(x: 300, y: 400))]
        XCTAssertEqual(PinLayout.groupSpots(spots), [1: 1, 3: 0])
        // The selected spot keeps its own pin even when a better spot overlaps it.
        XCTAssertEqual(PinLayout.groupSpots(spots, keep: 2), [2: 1, 3: 0])
        // Zoomed in, nothing overlaps and every spot has its own pin.
        let apart: [(id: Int, point: CGPoint)] = [(1, CGPoint(x: 0, y: 0)), (2, CGPoint(x: 200, y: 0))]
        XCTAssertEqual(PinLayout.groupSpots(apart), [1: 0, 2: 0])
    }

    func testSelectedPinAlwaysShows() {
        let point = CGPoint(x: 50, y: 50)
        let result = PinLayout.visible([
            PinLayout.Candidate(id: "rival", kind: .rival, point: point),
            PinLayout.Candidate(id: "store", kind: .cdcStore, point: point),
        ], reserved: [], bounds: CGRect(x: 0, y: 0, width: 100, height: 100), alwaysShow: ["rival"])
        XCTAssertTrue(result.visible.contains("rival"))
    }
}

final class ReviewTests: XCTestCase {
    func testSeedReportsIncludeAgreeingAndDisagreeingChecks() {
        let model = SiteModel(persists: false)
        let verdicts = Set(model.pendingReports.map(\.check.verdict))
        XCTAssertTrue(verdicts.contains(.agrees))
        XCTAssertTrue(verdicts.contains(.disagrees))
    }

    /// The seeded report about the rival nobody has checked for longest.
    private func staleRivalReport(_ model: SiteModel) throws -> (Report, String) {
        let report = try XCTUnwrap(model.pendingReports.first { report in
            if case .place(let id) = report.target { return model.place(id)?.kind == .rival }
            return false
        })
        guard case .place(let id) = report.target else { throw XCTSkip("unexpected target") }
        return (report, id)
    }

    func testPendingReportsDoNotChangeTheMap() throws {
        let model = SiteModel(persists: false)
        let (_, rivalID) = try staleRivalReport(model)
        XCTAssertNotNil(model.place(rivalID), "A report alone must not remove anything")
        XCTAssertTrue(model.appliedEdits.isEmpty)
    }

    func testApprovingAReportUpdatesTheMapAndUndoRestoresIt() throws {
        let model = SiteModel(persists: false)
        let (report, rivalID) = try staleRivalReport(model)
        model.approve(report)
        XCTAssertNil(model.place(rivalID))
        let applied = try XCTUnwrap(model.appliedEdits.last)
        model.undo(applied)
        XCTAssertNotNil(model.place(rivalID))
        XCTAssertEqual(model.reports.first { $0.id == report.id }?.status, .pending)
    }

    func testRejectingAReportLeavesTheMapAlone() throws {
        let model = SiteModel(persists: false)
        let report = try XCTUnwrap(model.pendingReports.first { $0.target == .place("argyle") })
        model.reject(report)
        XCTAssertNotNil(model.place("argyle"))
        XCTAssertEqual(model.reports.first { $0.id == report.id }?.status, .rejected)
    }

    func testSkippingASpotReplacesItAndRestoringBringsItBack() {
        let model = SiteModel(persists: false)
        let top = model.spots[0]
        let count = model.spots.count
        model.skipSpot(top.id, reason: SiteModel.skipReasons[0])
        XCTAssertFalse(model.spots.contains { $0.id == top.id })
        XCTAssertEqual(model.spots.count, count)
        model.clearDecision(top.id)
        XCTAssertEqual(model.spots.first?.id, top.id)
    }

    func testApprovedSpotsGoIntoThePilotFirst() {
        let model = SiteModel(persists: false)
        let fifth = model.spots[4]
        model.approveSpot(fifth.id)
        XCTAssertEqual(model.pilotSites.first?.id, fifth.id)
        XCTAssertEqual(model.pilotSites.count, 3)
    }

    func testDistrictRankingCoversEveryDistrict() {
        let model = SiteModel(persists: false)
        XCTAssertEqual(model.districtRows.count, AreaData.districts.count)
        XCTAssertEqual(model.districtRows.first?.best?.id, model.bestSpot?.id,
                       "The best district's best block is the overall best place")
    }

    func testZoomedOutMapDrawsGroupsAndZoomedInDrawsBlocks() {
        let model = SiteModel(persists: false)
        let coarse = model.drawCells(in: nil, zoom: 10)
        let fine = model.drawCells(in: nil, zoom: 15)
        XCTAssertTrue(coarse.allSatisfy { $0.id.hasPrefix("c") })
        XCTAssertTrue(fine.allSatisfy { $0.id.hasPrefix("b") })
        XCTAssertLessThan(coarse.count, fine.count / 3, "Grouping 3×3 should cut the drawing work")
    }

    func testQualityMetricsCoverTheReportsList() {
        let model = SiteModel(persists: false)
        let ids = Set(model.qualityMetrics.map(\.id))
        XCTAssertEqual(ids, ["error", "search", "fresh", "precision", "acceptance"])
    }
}
