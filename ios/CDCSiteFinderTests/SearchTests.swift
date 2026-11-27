import XCTest
@testable import CDCSiteFinder

/// "Keep a test set of real queries and track how often the first result is right."
final class SearchTests: XCTestCase {
    private let engine = SiteEngine()

    private var spots: [Spot] {
        engine.shortlist(from: engine.blocks(weights: .starting), weights: .starting)
    }

    func testBenchmarkQueriesFindTheRightResultFirst() {
        let result = SearchBenchmark.run(spots: spots, data: engine.data)
        XCTAssertGreaterThanOrEqual(result.rate, 0.9, "First-result success fell below 90%: \(result.failures)")
        XCTAssertTrue(result.failures.isEmpty, "Regressions: \(result.failures)")
    }

    func testOneLetterTyposStillMatch() {
        XCTAssertNotNil(SearchIndex.matchRank("kowlon tong", in: "Kowloon Tong 九龍塘 · District"))
        XCTAssertNotNil(SearchIndex.matchRank("la sale", in: "La Salle College"))
        XCTAssertNil(SearchIndex.matchRank("xyzzy", in: "Kowloon Tong"))
    }

    func testExactPrefixRanksAboveTypo() {
        let exact = SearchIndex.matchRank("mong", in: "Mong Kok")
        let typo = SearchIndex.matchRank("moong kok", in: "Mong Kok")
        XCTAssertEqual(exact, 0)
        XCTAssertNotNil(typo)
        XCTAssertLessThan(exact ?? 9, typo ?? 9)
    }

    func testShortQueriesNeedAnExactPrefix() {
        // Three letters is too short to guess at a typo; "kok" shouldn't match "Kai Tak".
        XCTAssertNil(SearchIndex.matchRank("kok", in: "Kai Tak Garden"))
    }

    func testEmptyQueryReturnsNothing() {
        XCTAssertTrue(SearchIndex.results(for: "   ", spots: spots, data: engine.data).isEmpty)
    }
}
