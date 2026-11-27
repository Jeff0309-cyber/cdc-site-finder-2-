import Foundation

/// A latitude/longitude pair. Kept free of CoreLocation so the scoring engine is plain Swift.
struct Coordinate: Hashable, Codable {
    var latitude: Double
    var longitude: Double

    init(_ latitude: Double, _ longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

enum Geo {
    /// Distance in metres. An equirectangular approximation is accurate to well under 1% at city scale.
    static func meters(_ a: Coordinate, _ b: Coordinate) -> Double {
        let midLatitude = (a.latitude + b.latitude) / 2 * .pi / 180
        let dx = (b.longitude - a.longitude) * cos(midLatitude) * 111_320
        let dy = (b.latitude - a.latitude) * 110_540
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Compass bearing from `a` to `b`, in degrees clockwise from north.
    static func bearing(from a: Coordinate, to b: Coordinate) -> Double {
        let midLatitude = (a.latitude + b.latitude) / 2 * .pi / 180
        let dx = (b.longitude - a.longitude) * cos(midLatitude) * 111_320
        let dy = (b.latitude - a.latitude) * 110_540
        let degrees = atan2(dx, dy) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    static func formatDistance(_ meters: Double) -> String {
        guard meters.isFinite else { return "—" }
        return meters < 1000 ? "\(Int((meters / 10).rounded() * 10)) m" : String(format: "%.1f km", meters / 1000)
    }

    /// "about 21,000" for explanations, rounded so it doesn't pretend to be exact.
    static func roughCount(_ value: Double) -> String {
        let rounded = value >= 10_000 ? (value / 1000).rounded() * 1000 : (value / 100).rounded() * 100
        return Int(rounded).formatted()
    }
}

enum PlaceKind: String, CaseIterable, Codable {
    case cdcStore, university, school, office, mtr, rival

    var title: String {
        switch self {
        case .cdcStore: "Café de Coral"
        case .university: "University campus"
        case .school: "School"
        case .office: "Office cluster"
        case .mtr: "MTR station"
        case .rival: "Rival fast-food outlet"
        }
    }

    /// Which pins win when two would overlap on screen. Lower wins.
    var priority: Int {
        switch self {
        case .cdcStore: 0
        case .university: 1
        case .mtr: 2
        case .office: 3
        case .school: 4
        case .rival: 5
        }
    }
}

enum Freshness {
    /// Shops and restaurants nobody has checked for longer than this are flagged "needs a check".
    static let staleAfterDays = 730

    static func describe(daysAgo: Int) -> String {
        switch daysAgo {
        case 0: "today"
        case 1: "yesterday"
        case ..<60: "\(daysAgo) days ago"
        case ..<730: "\(daysAgo / 30) months ago"
        default: "\(daysAgo / 365) years ago"
        }
    }

    /// "120 days", "5 months", "3 years": for sentences like "not checked for 3 years".
    static func duration(days: Int) -> String {
        switch days {
        case ..<60: "\(days) day\(days == 1 ? "" : "s")"
        case ..<730: "\(days / 30) months"
        default: "\(days / 365) years"
        }
    }
}

struct Place: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let nameZH: String
    let kind: PlaceKind
    let coordinate: Coordinate
    /// Address for stores, a one-line note for everything else.
    let detail: String
    /// Other names people search for: abbreviations, old names, Cantonese names.
    var aliases: [String] = []
    /// Days since someone last checked the place: its last OpenStreetMap edit, or the branch list date.
    var confirmedDaysAgo: Int = 7
    /// Index into `AreaData.districts`.
    var district: Int = 0
    var source: String = "OpenStreetMap"

    /// Restaurants open and close; schools and stations come from official lists and rarely change.
    var isStale: Bool {
        (kind == .cdcStore || kind == .rival) && confirmedDaysAgo > Freshness.staleAfterDays
    }
}

struct District: Identifiable, Hashable {
    var id: Int { index }
    let index: Int
    let key: String
    let name: String
    let nameZH: String
    let population: Int
    /// Neighbourhoods people search for, such as Tseung Kwan O for Sai Kung.
    let aliases: [String]
    /// Population-weighted centre, so "go to Sai Kung" lands on Tseung Kwan O, not the country park.
    let center: Coordinate

    var title: String { "\(name) District" }
}

/// One street block's raw inputs, from the dataset.
struct RasterCell {
    let id: Int
    let residents: Double
    let office: Double
    let shops: Double
    let district: Int
}

/// The map database: every place the engine scores against.
/// Approved reports change it through `DataEdit`s, which keeps every change reversible.
struct AreaDataset: Equatable {
    var stores: [Place]
    var universities: [Place]
    var schools: [Place]
    var offices: [Place]
    var stations: [Place]
    var rivals: [Place]

    var allPlaces: [Place] { stores + universities + offices + stations + schools + rivals }

    static let base = AreaDataset(
        stores: AreaData.places(.cdcStore), universities: AreaData.places(.university), schools: AreaData.places(.school),
        offices: AreaData.officeClusters, stations: AreaData.places(.mtr), rivals: AreaData.places(.rival))

    func applying(_ edits: [DataEdit]) -> AreaDataset {
        var data = self
        for edit in edits { data.apply(edit) }
        return data
    }

    mutating func apply(_ edit: DataEdit) {
        switch edit {
        case .removePlace(let id):
            // Keep at least one store, so "sales taken from the nearest CDC" always has an answer.
            if stores.count == 1, stores[0].id == id { return }
            for kind in PlaceKind.allCases { update(kind) { $0.removeAll { $0.id == id } } }
        case .addPlace(let place):
            update(place.kind) { list in
                if !list.contains(where: { $0.id == place.id }) { list.append(place) }
            }
        case .confirmPlace(let id):
            for kind in PlaceKind.allCases {
                update(kind) { list in
                    for index in list.indices where list[index].id == id { list[index].confirmedDaysAgo = 0 }
                }
            }
        case .excludeBlock:
            break
        }
    }

    private mutating func update(_ kind: PlaceKind, _ change: (inout [Place]) -> Void) {
        switch kind {
        case .cdcStore: change(&stores)
        case .university: change(&universities)
        case .school: change(&schools)
        case .office: change(&offices)
        case .mtr: change(&stations)
        case .rival: change(&rivals)
        }
    }
}

/// The bundled Hong Kong data, ready to use.
enum AreaData {
    static let name = "Hong Kong"
    static let center = Coordinate(22.365, 114.125)
    /// Camera zoom that fits the whole territory on an iPhone.
    static let defaultZoom: Float = 10.25
    /// Café de Coral's Hong Kong store count (FY25/26 results). The dataset maps fewer, so coverage
    /// is shown per district and fed into each spot's confidence.
    static let estimatedStoreTotal = 168

    static var source: String { HKData.places.source }

    static let raster: [RasterCell] = HKData.cells.cells.map { row in
        RasterCell(id: Int(row[0]), residents: row[1], office: row[2], shops: row[3], district: Int(row[4]))
    }

    static let districts: [District] = {
        var weighted = Array(repeating: (lat: 0.0, lon: 0.0, weight: 0.0), count: HKData.places.districts.count)
        for cell in raster where cell.residents > 0 {
            let center = SiteEngine.Grid.center(of: cell.id)
            weighted[cell.district].lat += center.latitude * cell.residents
            weighted[cell.district].lon += center.longitude * cell.residents
            weighted[cell.district].weight += cell.residents
        }
        return HKData.places.districts.enumerated().map { index, record in
            let w = weighted[index]
            let center = w.weight > 0 ? Coordinate(w.lat / w.weight, w.lon / w.weight) : AreaData.center
            return District(index: index, key: record.key, name: record.name, nameZH: record.nameZH,
                            population: record.population, aliases: districtAliases[record.key] ?? [], center: center)
        }
    }()

    static func places(_ kind: PlaceKind) -> [Place] {
        HKData.places.places.compactMap { record in
            guard record.kind == kind.rawValue else { return nil }
            let coordinate = Coordinate(record.lat, record.lon)
            return Place(id: record.id, name: record.name, nameZH: record.nameZH, kind: kind, coordinate: coordinate,
                         detail: record.detail, aliases: (record.aliases ?? []) + aliases(for: record.name, kind: kind),
                         confirmedDaysAgo: record.confirmedDaysAgo, district: record.district,
                         source: record.source ?? "OpenStreetMap")
        }
    }

    /// Office pins: the densest office blocks, at least 1.2 km apart, named by their MTR station.
    /// The scoring uses every office building; these pins just show where the clusters are.
    static let officeClusters: [Place] = {
        let stations = places(.mtr)
        var picked: [RasterCell] = []
        for cell in raster.filter({ $0.office >= 150 }).sorted(by: { $0.office > $1.office }) where picked.count < 30 {
            let center = SiteEngine.Grid.center(of: cell.id)
            if picked.allSatisfy({ Geo.meters(SiteEngine.Grid.center(of: $0.id), center) >= 1200 }) {
                picked.append(cell)
            }
        }
        return picked.map { cell in
            let center = SiteEngine.Grid.center(of: cell.id)
            let station = SiteEngine.nearest(stations, to: center)?.place
            let near = station.map { $0.name.replacingOccurrences(of: " station", with: "") } ?? "Hong Kong"
            let nearZH = station.map { String($0.nameZH.dropLast()) } ?? "香港"
            return Place(id: "office-\(cell.id)", name: "\(near) office cluster", nameZH: "\(nearZH)商業區", kind: .office,
                         coordinate: center, detail: "Office and commercial buildings (OpenStreetMap)",
                         confirmedDaysAgo: 30, district: cell.district, source: "OpenStreetMap")
        }
    }()

    private static func aliases(for name: String, kind: PlaceKind) -> [String] {
        guard kind == .university else { return [] }
        return universityAliases.first { name.hasPrefix($0.match) }?.aliases ?? []
    }

    private static let universityAliases: [(match: String, aliases: [String])] = [
        ("City University of Hong Kong", ["CityU", "城大"]),
        ("The Chinese University of Hong Kong", ["CUHK", "中大"]),
        ("The University of Hong Kong", ["HKU", "港大"]),
        ("HKU", ["HKU", "港大"]),
        ("The Hong Kong University of Science and Technology", ["HKUST", "UST", "科大"]),
        ("The Hong Kong Polytechnic University", ["PolyU", "理大"]),
        ("Hong Kong Baptist University", ["HKBU", "浸大"]),
        ("Lingnan University", ["嶺大"]),
        ("The Education University of Hong Kong", ["EdUHK", "教大"]),
        ("Hong Kong Metropolitan University", ["HKMU", "Open University", "公開大學", "都大"]),
        ("Hong Kong Shue Yan University", ["Shue Yan", "樹仁"]),
        ("The Hang Seng University of Hong Kong", ["HSUHK", "恒大"]),
    ]

    private static let districtAliases: [String: [String]] = [
        "central": ["Central", "Sheung Wan", "Sai Ying Pun", "Kennedy Town", "Mid-Levels", "中環", "上環", "堅尼地城"],
        "wanchai": ["Causeway Bay", "Happy Valley", "CWB", "銅鑼灣", "跑馬地"],
        "eastern": ["North Point", "Quarry Bay", "Tai Koo", "Shau Kei Wan", "Chai Wan", "北角", "鰂魚涌", "太古", "柴灣"],
        "southern": ["Aberdeen", "Ap Lei Chau", "Stanley", "Wong Chuk Hang", "香港仔", "鴨脷洲", "赤柱"],
        "ytm": ["Mong Kok", "Tsim Sha Tsui", "TST", "Jordan", "Yau Ma Tei", "旺角", "尖沙咀", "佐敦", "油麻地"],
        "ssp": ["Cheung Sha Wan", "Mei Foo", "Lai Chi Kok", "Shek Kip Mei", "長沙灣", "美孚", "荔枝角"],
        "kc": ["Hung Hom", "Kai Tak", "To Kwa Wan", "Ho Man Tin", "紅磡", "啟德", "土瓜灣", "何文田"],
        "wts": ["Diamond Hill", "Lok Fu", "Tsz Wan Shan", "San Po Kong", "鑽石山", "樂富", "慈雲山", "新蒲崗"],
        "kt": ["Kowloon Bay", "Lam Tin", "Ngau Tau Kok", "Yau Tong", "九龍灣", "藍田", "牛頭角", "油塘"],
        "kwaitsing": ["Tsing Yi", "Kwai Fong", "Kwai Chung", "Kwai Hing", "青衣", "葵芳", "葵涌", "葵興"],
        "tsuenwan": ["Tsuen Wan West", "Ma Wan", "荃灣西", "馬灣"],
        "tuenmun": ["Siu Hong", "Tuen Mun Town Centre", "兆康", "屯門市中心"],
        "yuenlong": ["Tin Shui Wai", "Long Ping", "TSW", "天水圍", "朗屏"],
        "north": ["Sheung Shui", "Fanling", "上水", "粉嶺"],
        "taipo": ["Tai Po Market", "Tai Wo", "大埔墟", "太和"],
        "shatin": ["Ma On Shan", "Tai Wai", "Fo Tan", "MOS", "馬鞍山", "大圍", "火炭"],
        "saikung": ["Tseung Kwan O", "TKO", "Hang Hau", "LOHAS Park", "將軍澳", "坑口", "康城"],
        "islands": ["Tung Chung", "Lantau", "Discovery Bay", "Cheung Chau", "東涌", "大嶼山", "愉景灣", "長洲"],
    ]
}
