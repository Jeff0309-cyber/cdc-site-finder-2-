import Foundation

/// Search across spots, districts and places. Tolerates typos, abbreviations (CityU, MK),
/// Chinese names (旺角) and addresses (Nathan Road), as the maps report asks for.
enum SearchIndex {
    private struct Entry {
        let result: SearchResult
        let text: String
    }

    static func results(for query: String, spots: [Spot], data: AreaDataset, limit: Int = 8) -> [SearchResult] {
        let normalisedQuery = normalise(query)
        guard !normalisedQuery.isEmpty else { return [] }
        let scored = entries(spots: spots, data: data).enumerated().compactMap { index, entry -> (SearchResult, Int, Int)? in
            matchRank(normalisedQuery, in: entry.text).map { (entry.result, $0, index) }
        }
        // Rank first, then original order (spots, districts, places), so results never jump around.
        return scored.sorted { ($0.1, $0.2) < ($1.1, $1.2) }.prefix(limit).map(\.0)
    }

    private static func entries(spots: [Spot], data: AreaDataset) -> [Entry] {
        func placeEntry(_ place: Place) -> Entry {
            let title = place.kind == .cdcStore ? "Café de Coral · \(place.name)" : place.name
            let result = SearchResult(
                id: place.id, title: title, subtitle: "\(place.nameZH) · \(place.kind.title)",
                symbol: MapLayer.layer(for: place.kind).symbol, target: .route(.place(place.id)),
                coordinate: place.coordinate)
            let extra = place.kind == .cdcStore ? ["cdc", "大家樂", "cafe de coral"] : []
            return Entry(result: result,
                         text: ([title, result.subtitle, place.detail] + place.aliases + extra).joined(separator: " "))
        }

        // Order breaks ties between equally good matches: spots, then stations (what people mean by
        // "Mong Kok"), then districts, then everything else.
        var entries: [Entry] = spots.map { spot in
            let result = SearchResult(
                id: "spot-\(spot.id)", title: spot.title,
                subtitle: "Score \(spot.block.score) · ~\(Int(spot.block.netOrders.rounded())) orders a day",
                symbol: "star.fill", target: .route(.spot(spot.id)), coordinate: spot.block.center)
            return Entry(result: result, text: "\(result.title) spot \(spot.letter)")
        }
        entries += data.stations.map(placeEntry)
        entries += AreaData.districts.map { district in
            let result = SearchResult(
                id: "district-\(district.key)", title: district.title,
                subtitle: "\(district.nameZH) · \(district.population.formatted()) people",
                symbol: "mappin.and.ellipse", target: .area(district.center), coordinate: district.center)
            return Entry(result: result,
                         text: ([district.title, district.nameZH] + district.aliases).joined(separator: " "))
        }
        entries += (data.stores + data.universities + data.offices + data.rivals + data.schools).map(placeEntry)
        return entries
    }

    static func normalise(_ text: String) -> String {
        text.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// Lower is better: whole-string prefix, then every word matched by prefix, then substring,
    /// then every word matched with one typo.
    static func matchRank(_ query: String, in text: String) -> Int? {
        let q = normalise(query)
        let t = normalise(text)
        guard !q.isEmpty else { return nil }
        if t.hasPrefix(q) { return 0 }

        let queryTokens = tokens(q)
        let words = tokens(t)
        guard !queryTokens.isEmpty else { return t.contains(q) ? 2 : nil }

        if queryTokens.allSatisfy({ token in words.contains { $0.hasPrefix(token) } }) { return 1 }

        // "mongkok" for "Mong Kok": two whole words written together count as a word match, so the
        // station (listed before schools) beats "Beacon Education Centre (Mongkok)".
        let compact = queryTokens.joined()
        let pairs = words.indices.dropLast().map { words[$0] + words[$0 + 1] }
        if compact.count >= 4, pairs.contains(compact) { return 1 }

        if t.contains(q) { return 2 }

        // A whole word plus the start of the next one ranks lower, so "hkust" finds HKUST rather
        // than "HKU station".
        if compact.count >= 4, pairs.contains(where: { $0.hasPrefix(compact) }) { return 2 }

        if queryTokens.contains(where: { $0.count >= 4 }),
           queryTokens.allSatisfy({ token in words.contains { fuzzyPrefix(token, $0) } }) {
            return 3
        }
        return nil
    }

    /// True if `token` starts `word`, allowing one typo (two for long words).
    static func fuzzyPrefix(_ token: String, _ word: String) -> Bool {
        if word.hasPrefix(token) { return true }
        guard token.count >= 4 else { return false }
        let allowed = token.count >= 8 ? 2 : 1
        for length in [token.count - 1, token.count, token.count + 1] where length > 0 && length <= word.count {
            if editDistance(token, String(word.prefix(length))) <= allowed { return true }
        }
        return false
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}

/// Real queries the team would type, with what the first result should be. Run in the Quality tab
/// and in the unit tests, as the maps report's checklist recommends.
enum SearchBenchmark {
    struct Case {
        let query: String
        /// Text the first result's title must contain.
        let expected: String
        let note: String
    }

    struct Result {
        let passed: Int
        let total: Int
        let failures: [String]

        var rate: Double { total == 0 ? 0 : Double(passed) / Double(total) }
    }

    static let cases: [Case] = [
        Case(query: "mong kok", expected: "Mong Kok", note: "station name"),
        Case(query: "mongkok", expected: "Mong Kok", note: "written together"),
        Case(query: "旺角", expected: "Mong Kok", note: "Chinese name"),
        Case(query: "kowlon tong", expected: "Kowloon Tong", note: "typo"),
        Case(query: "tsuen wann", expected: "Tsuen Wan", note: "typo"),
        Case(query: "tai po", expected: "Tai Po", note: "district or station"),
        Case(query: "tko", expected: "Sai Kung", note: "neighbourhood abbreviation"),
        Case(query: "將軍澳", expected: "Tseung Kwan O", note: "Chinese name"),
        Case(query: "tin shui wai", expected: "Tin Shui Wai", note: "neighbourhood"),
        Case(query: "tung chung", expected: "Tung Chung", note: "neighbourhood"),
        Case(query: "cityu", expected: "City University", note: "abbreviation"),
        Case(query: "城大", expected: "City University", note: "Cantonese short name"),
        Case(query: "polyu", expected: "Polytechnic", note: "abbreviation"),
        Case(query: "hkust", expected: "Science and Technology", note: "abbreviation"),
        Case(query: "中大", expected: "Chinese University", note: "Cantonese short name"),
        Case(query: "open university", expected: "Metropolitan", note: "old name"),
        Case(query: "大家樂", expected: "Café de Coral", note: "brand in Chinese"),
        Case(query: "nathan road", expected: "Café de Coral", note: "store address"),
        Case(query: "fairwood", expected: "Fairwood", note: "rival brand"),
        Case(query: "麥當勞", expected: "McDonald's", note: "rival in Chinese"),
    ]

    static func run(spots: [Spot], data: AreaDataset) -> Result {
        var all = cases
        if let top = spots.first {
            all.append(Case(query: "spot a", expected: top.title, note: "shortlist letter"))
        }
        var failures: [String] = []
        for testCase in all {
            let first = SearchIndex.results(for: testCase.query, spots: spots, data: data, limit: 1).first
            if !(first?.title.contains(testCase.expected) ?? false) {
                failures.append("\"\(testCase.query)\" (\(testCase.note)) → \(first?.title ?? "no result")")
            }
        }
        return Result(passed: all.count - failures.count, total: all.count, failures: failures)
    }
}
