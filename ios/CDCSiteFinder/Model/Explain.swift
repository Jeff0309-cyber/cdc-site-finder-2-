import Foundation

/// Describes a place the way people in Hong Kong give directions: by MTR station and landmark,
/// not by coordinates or street numbers.
enum Wayfinding {
    struct Directions: Equatable {
        let english: String
        let chinese: String
        /// For list rows: "4 min from Kowloon Tong station".
        let short: String
        let walkMinutes: Int?
        let station: Place?
    }

    /// Metres a minute at a normal walking pace.
    static let walkingSpeed = 80.0
    /// Streets are longer than a straight line; Kowloon's grid adds about 30%.
    static let detour = 1.3

    static func walkMinutes(_ meters: Double) -> Int {
        max(1, Int((meters * detour / walkingSpeed).rounded()))
    }

    static func compass(_ bearing: Double) -> (english: String, chinese: String) {
        let names = [("north", "北"), ("north-east", "東北"), ("east", "東"), ("south-east", "東南"),
                     ("south", "南"), ("south-west", "西南"), ("west", "西"), ("north-west", "西北")]
        let normalised = (bearing.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return names[Int((normalised + 22.5) / 45) % 8]
    }

    static func describe(_ point: Coordinate, data: AreaDataset) -> Directions {
        let landmark = nearestLandmark(to: point, data: data)
        guard let nearest = SiteEngine.nearest(data.stations, to: point) else {
            let english = landmark.map { "Next to \($0.name)" } ?? "No MTR station nearby"
            let chinese = landmark.map { "近\($0.nameZH)" } ?? "附近沒有港鐵站"
            return Directions(english: english, chinese: chinese, short: english, walkMinutes: nil, station: nil)
        }

        let station = nearest.place
        let minutes = walkMinutes(nearest.distance)
        var english: String
        var chinese: String
        let short: String
        if nearest.distance < 120 {
            english = "Right outside \(station.name)"
            chinese = "\(station.nameZH)出口附近"
            short = "At \(station.name)"
        } else {
            let direction = compass(Geo.bearing(from: station.coordinate, to: point))
            english = "\(minutes) min walk \(direction.english) of \(station.name)"
            chinese = "\(station.nameZH)\(direction.chinese)面步行約\(minutes)分鐘"
            short = "\(minutes) min from \(station.name)"
        }
        if let landmark {
            english += ", next to \(landmark.name)"
            chinese += "，近\(landmark.nameZH)"
        }
        return Directions(english: english, chinese: chinese, short: short, walkMinutes: minutes, station: station)
    }

    /// The closest named landmark (campus, school or office) within a short walk.
    static func nearestLandmark(to point: Coordinate, data: AreaDataset) -> Place? {
        guard let hit = SiteEngine.nearest(data.universities + data.schools + data.offices, to: point),
              hit.distance < 300 else { return nil }
        return hit.place
    }
}

/// Plain-language reasons for a score, so nobody has to read the bars to know why.
enum Explain {
    static func why(_ block: Block, weights: Weights, data: AreaDataset, rank: Int?) -> String {
        let drivers: [Feature] = [.appOrders, .schools, .offices, .footfall]
        let strong = drivers
            .filter { (block.features[$0] ?? 0) >= 0.35 }
            .sorted { block.contribution($0, weights: weights) > block.contribution($1, weights: weights) }
            .prefix(2)
        let drag = [Feature.rivals, .rent]
            .filter { abs(block.contribution($0, weights: weights)) >= 0.025 }
            .max { abs(block.contribution($0, weights: weights)) < abs(block.contribution($1, weights: weights)) }

        guard !strong.isEmpty else {
            return "Low demand here: none of the four demand inputs is strong."
        }
        let lead = rank.map { "Ranked #\($0) because of " } ?? "Scores \(block.score) because of "
        var sentence = lead + strong.map { phrase(for: $0, block: block, data: data) }.joined(separator: " and ") + "."
        if let drag {
            sentence += " Held back by \(phrase(for: drag, block: block, data: data))."
        }
        return sentence
    }

    static func phrase(for feature: Feature, block: Block, data: AreaDataset) -> String {
        switch feature {
        case .appOrders:
            return "about \(Geo.roughCount(block.catchment)) residents within a 5-minute walk and no CDC nearby"
        case .schools:
            if let hit = SiteEngine.nearest(data.universities + data.schools, to: block.center), hit.distance < 650 {
                return "\(hit.place.name) \(Geo.formatDistance(hit.distance)) away"
            }
            return "schools nearby"
        case .offices:
            if let hit = SiteEngine.nearest(data.offices, to: block.center), hit.distance < 650 {
                return "office workers at \(hit.place.name)"
            }
            return "office workers nearby"
        case .footfall:
            if let hit = SiteEngine.nearest(data.stations, to: block.center) {
                return "foot traffic from \(hit.place.name)"
            }
            return "busy streets"
        case .rivals:
            let count = data.rivals.filter { Geo.meters($0.coordinate, block.center) < 350 }.count
            switch count {
            case 0: return "rivals nearby"
            case 1: return "a rival within 350 m"
            default: return "\(count) rivals within 350 m"
            }
        case .rent:
            return "high rents"
        }
    }

    /// Sentences comparing a spot with the top pick, for the compare view.
    static func tradeOffs(_ spot: Spot, against top: Spot, weights: Weights) -> [String] {
        var lines: [String] = []
        let orderGap = Int((spot.block.netOrders - top.block.netOrders).rounded())
        if orderGap != 0 {
            lines.append(orderGap > 0 ? "\(orderGap) more new orders a day than \(top.letter)."
                                      : "\(-orderGap) fewer new orders a day than \(top.letter).")
        }
        let cannibalGap = spot.block.cannibalisation - top.block.cannibalisation
        if abs(cannibalGap) >= 0.02 {
            lines.append(cannibalGap > 0
                         ? "Takes more sales from \(spot.block.nearestStore.name) (\(percentText(spot.block.cannibalisation)))."
                         : "Takes fewer sales from existing stores (\(percentText(spot.block.cannibalisation)) vs \(percentText(top.block.cannibalisation))).")
        }
        let rentGap = (spot.block.features[.rent] ?? 0) - (top.block.features[.rent] ?? 0)
        if abs(rentGap) >= 0.2 {
            lines.append(rentGap > 0 ? "Higher rent than \(top.letter)." : "Lower rent than \(top.letter).")
        }
        let rivalGap = (spot.block.features[.rivals] ?? 0) - (top.block.features[.rivals] ?? 0)
        if abs(rivalGap) >= 0.2 {
            lines.append(rivalGap > 0 ? "More rivals nearby than \(top.letter)." : "Fewer rivals nearby than \(top.letter).")
        }
        let schoolsGap = (spot.block.features[.schools] ?? 0) - (top.block.features[.schools] ?? 0)
        if abs(schoolsGap) >= 0.25 {
            lines.append(schoolsGap > 0 ? "More after-school demand." : "Less after-school demand.")
        }
        let officeGap = (spot.block.features[.offices] ?? 0) - (top.block.features[.offices] ?? 0)
        if abs(officeGap) >= 0.25 {
            lines.append(officeGap > 0 ? "Busier at lunch with office workers." : "Fewer office workers at lunch.")
        }
        return lines.isEmpty ? ["Close to \(top.letter) on every input."] : lines
    }

    static func percentText(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
}
