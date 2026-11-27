import Foundation

/// Loads the bundled Hong Kong dataset in `Resources/`.
///
/// Built by `tools/build_dataset.py` from OpenStreetMap (© OpenStreetMap contributors, ODbL),
/// the 2021 Population Census district totals and the published Café de Coral branch list.
enum HKData {
    /// Where the JSON files live. The app reads its bundle; command-line checks can point elsewhere.
    static var directory: URL?

    struct PlacesFile: Decodable {
        let source: String
        let districts: [DistrictRecord]
        let places: [PlaceRecord]
    }

    struct DistrictRecord: Decodable {
        let key: String
        let name: String
        let nameZH: String
        let population: Int
    }

    struct PlaceRecord: Decodable {
        let id: String
        let kind: String
        let name: String
        let nameZH: String
        let lat: Double
        let lon: Double
        let detail: String
        let confirmedDaysAgo: Int
        let district: Int
        let aliases: [String]?
        let source: String?
    }

    struct CellsFile: Decodable {
        struct GridRecord: Decodable {
            let minLat: Double
            let minLon: Double
            let latStep: Double
            let lonStep: Double
            let rows: Int
            let columns: Int
        }

        let grid: GridRecord
        /// Each row: block id, residents, office floor mass, shop count, district index.
        let cells: [[Double]]
    }

    static let places: PlacesFile = load("hk_places")
    static let cells: CellsFile = load("hk_cells")

    private static func url(for name: String) -> URL {
        if let directory { return directory.appendingPathComponent("\(name).json") }
        for bundle in [Bundle.main] + Bundle.allBundles {
            if let url = bundle.url(forResource: name, withExtension: "json") { return url }
        }
        fatalError("\(name).json is missing from the app bundle")
    }

    private static func load<T: Decodable>(_ name: String) -> T {
        do {
            return try JSONDecoder().decode(T.self, from: Data(contentsOf: url(for: name)))
        } catch {
            fatalError("Couldn't read \(name).json: \(error)")
        }
    }
}
