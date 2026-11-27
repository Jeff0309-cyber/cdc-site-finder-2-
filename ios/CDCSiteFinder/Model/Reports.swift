import Foundation

/// A change to the map database. Only approved reports and team actions create these,
/// and each one can be undone.
enum DataEdit: Codable, Hashable {
    case removePlace(id: String)
    case addPlace(Place)
    case confirmPlace(id: String)
    case excludeBlock(id: Int, reason: String)
}

enum ReportTarget: Codable, Hashable {
    case place(String)
    case block(Int)
}

enum ReportKind: String, Codable, CaseIterable, Identifiable {
    case closed, newRival, newOffice, noSpace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .closed: "Closed permanently"
        case .newRival: "A new rival opened here"
        case .newOffice: "A new office building here"
        case .noSpace: "No space for a locker"
        }
    }

    var symbol: String {
        switch self {
        case .closed: "xmark.octagon.fill"
        case .newRival: "storefront.fill"
        case .newOffice: "building.2.fill"
        case .noSpace: "square.slash"
        }
    }

    static func options(for target: ReportTarget) -> [ReportKind] {
        switch target {
        case .place: [.closed]
        case .block: [.newRival, .newOffice, .noSpace]
        }
    }
}

/// Tiered trust, as Waze does with map editors: anyone can report, but reports from people
/// who were on site carry more weight, and none of them change the map without a reviewer.
enum ReporterRole: String, Codable, CaseIterable, Identifiable {
    case fieldScout, storeStaff, member

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fieldScout: "Field scout"
        case .storeStaff: "Store staff"
        case .member: "Club 100 member"
        }
    }

    var trust: String {
        switch self {
        case .fieldScout: "High trust: checked on site"
        case .storeStaff: "Medium trust: works nearby"
        case .member: "Low trust: customer feedback"
        }
    }

    /// Higher is more trusted.
    var trustRank: Int {
        switch self {
        case .fieldScout: 2
        case .storeStaff: 1
        case .member: 0
        }
    }
}

enum ReportStatus: String, Codable {
    case pending, approved, rejected
}

/// What the automated check found when the report came in, before any person looked at it.
struct AutoCheck: Codable, Hashable {
    enum Verdict: String, Codable {
        case agrees, disagrees, unsure

        var title: String {
            switch self {
            case .agrees: "Check agrees"
            case .disagrees: "Check disagrees"
            case .unsure: "Check unsure"
            }
        }
    }

    let verdict: Verdict
    let detail: String
}

struct Report: Identifiable, Codable, Hashable {
    let id: UUID
    let target: ReportTarget
    let kind: ReportKind
    let role: ReporterRole
    let note: String
    let created: Date
    let check: AutoCheck
    var status: ReportStatus
    var reviewed: Date?
}

enum ReportChecks {
    /// Compares a new report with what the data already says. Sample rules standing in for
    /// listings refreshes, store sales and vacancy data.
    static func check(_ kind: ReportKind, target: ReportTarget, data: AreaDataset, block: (Int) -> Block?) -> AutoCheck {
        switch (kind, target) {
        case (.closed, .place(let id)):
            guard let place = data.allPlaces.first(where: { $0.id == id }) else {
                return AutoCheck(verdict: .agrees, detail: "Already removed from the map.")
            }
            switch place.kind {
            case .cdcStore:
                let meals = 1800 + Int(id.hashValueStable.magnitude % 900)
                return AutoCheck(verdict: .disagrees,
                                 detail: "This store sold about \(meals.formatted()) meals last week. A permanent closure would come from Operations, not a report.")
            case .rival:
                if place.isStale {
                    return AutoCheck(verdict: .agrees,
                                     detail: "Nobody has checked it on OpenStreetMap for \(Freshness.duration(days: place.confirmedDaysAgo)), so a closure is plausible.")
                }
                return AutoCheck(verdict: .disagrees,
                                 detail: "Listings confirmed it open \(Freshness.describe(daysAgo: place.confirmedDaysAgo)).")
            case .school, .university:
                return AutoCheck(verdict: .disagrees, detail: "Still on the Education Bureau school list.")
            case .mtr:
                return AutoCheck(verdict: .disagrees, detail: "MTR still lists this station as open.")
            case .office:
                return AutoCheck(verdict: .unsure,
                                 detail: "Office data was last refreshed \(Freshness.describe(daysAgo: place.confirmedDaysAgo)).")
            }
        case (.newRival, .block(let id)):
            let rivals = block(id)?.features[.rivals] ?? 0
            return rivals < 0.2
                ? AutoCheck(verdict: .unsure,
                            detail: "No rival is listed within 250 m yet. The next weekly listings refresh will confirm it.")
                : AutoCheck(verdict: .agrees, detail: "Listings already show rivals close by, so one more fits the pattern.")
        case (.newOffice, .block):
            return AutoCheck(verdict: .unsure, detail: "Office data refreshes monthly, so this isn't confirmed yet.")
        case (.noSpace, .block(let id)):
            let rent = block(id)?.features[.rent] ?? 0
            return rent > 0.45
                ? AutoCheck(verdict: .agrees, detail: "Few vacant ground-floor units are listed in this high-rent block.")
                : AutoCheck(verdict: .unsure, detail: "\(2 + id % 4) vacant units are listed nearby. Worth a second look.")
        default:
            return AutoCheck(verdict: .unsure, detail: "No automated check for this kind of report.")
        }
    }

    /// The map change an approved report makes.
    static func edit(for report: Report, blockCenter: Coordinate?) -> DataEdit? {
        switch (report.kind, report.target) {
        case (.closed, .place(let id)):
            return .removePlace(id: id)
        case (.newRival, .block(let id)):
            guard let center = blockCenter else { return nil }
            return .addPlace(Place(id: "reported-rival-\(id)", name: "New rival (reported)", nameZH: "新對手",
                                   kind: .rival, coordinate: center, detail: "Reported by \(report.role.title.lowercased())",
                                   confirmedDaysAgo: 0))
        case (.newOffice, .block(let id)):
            guard let center = blockCenter else { return nil }
            return .addPlace(Place(id: "reported-office-\(id)", name: "New office building (reported)",
                                   nameZH: "新寫字樓", kind: .office, coordinate: center,
                                   detail: "Reported by \(report.role.title.lowercased())", confirmedDaysAgo: 0))
        case (.noSpace, .block(let id)):
            return .excludeBlock(id: id, reason: "no space for a locker (\(report.role.title.lowercased()) report)")
        default:
            return nil
        }
    }

    /// Reports waiting in the queue on first launch, so the review flow has something to show.
    /// Reports waiting in the queue on first launch, so the review flow has something to show.
    static func seeds(data: AreaDataset, block: (Int) -> Block?, spots: [Spot], now: Date = Date()) -> [Report] {
        func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }
        func make(_ target: ReportTarget, _ kind: ReportKind, _ role: ReporterRole, _ note: String, _ age: Double) -> Report {
            Report(id: UUID(), target: target, kind: kind, role: role, note: note, created: daysAgo(age),
                   check: check(kind, target: target, data: data, block: block), status: .pending, reviewed: nil)
        }

        var seeds: [Report] = []
        // The rival nobody has checked for longest: store staff say it's gone.
        if let oldest = data.rivals.max(by: { $0.confirmedDaysAgo < $1.confirmedDaysAgo }) {
            seeds.append(make(.place(oldest.id), .closed, .storeStaff, "Shutters down for weeks and a 'for lease' sign is up.", 2))
        }
        // A customer says a busy CDC is closed: the automated check should disagree.
        if data.stores.contains(where: { $0.id == "argyle" }) {
            seeds.append(make(.place("argyle"), .closed, .member, "It was closed when I went at lunch??", 1))
        }
        if let id = SiteEngine.Grid.id(at: Coordinate(22.3290, 114.1655)), block(id) != nil {
            seeds.append(make(.block(id), .newRival, .storeStaff, "A new mainland noodle chain opened across the road.", 3))
        }
        // A field scout checked one of the shortlisted spots and found no room for a locker.
        if spots.count >= 5 {
            seeds.append(make(.block(spots[4].id), .noSpace, .fieldScout,
                              "Walked the block: no vacant ground-floor units, and the mall won't take a locker.", 4))
        }
        return seeds
    }
}

private extension String {
    /// `hashValue` changes between launches; this doesn't.
    var hashValueStable: Int {
        unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) }
    }
}
