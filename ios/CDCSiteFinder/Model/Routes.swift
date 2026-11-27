import Foundation

enum MapLayer: String, CaseIterable, Identifiable, Hashable, Codable {
    case demand, stores, schools, offices, mtr, rivals

    var id: String { rawValue }

    var title: String {
        switch self {
        case .demand: "Demand"
        case .stores: "CDC stores"
        case .schools: "Schools"
        case .offices: "Offices"
        case .mtr: "MTR"
        case .rivals: "Rivals"
        }
    }

    var symbol: String {
        switch self {
        case .demand: "square.grid.3x3.fill"
        case .stores: "fork.knife"
        case .schools: "graduationcap.fill"
        case .offices: "building.2.fill"
        case .mtr: "tram.fill"
        case .rivals: "storefront.fill"
        }
    }

    var kinds: [PlaceKind] {
        switch self {
        case .demand: []
        case .stores: [.cdcStore]
        case .schools: [.school, .university]
        case .offices: [.office]
        case .mtr: [.mtr]
        case .rivals: [.rival]
        }
    }

    static func layer(for kind: PlaceKind) -> MapLayer {
        allCases.first { $0.kinds.contains(kind) } ?? .stores
    }
}

/// What the bottom sheet is showing.
enum Route: Hashable, Codable {
    case spot(Int)
    case block(Int)
    case place(String)
    case compare
    case districts
}

struct CameraRequest: Equatable {
    let id = UUID()
    let center: Coordinate
    let zoom: Float
}

struct SearchResult: Identifiable, Hashable, Codable {
    enum Target: Hashable, Codable {
        case route(Route)
        case area(Coordinate)
    }

    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let target: Target
    let coordinate: Coordinate
}

/// Tabs of the "Model, data and quality" sheet.
enum ControlTab: String, CaseIterable, Identifiable {
    case model, data, reviews, quality

    var id: String { rawValue }

    var title: String {
        switch self {
        case .model: "Model"
        case .data: "Data"
        case .reviews: "Reviews"
        case .quality: "Quality"
        }
    }
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let symbol: String
}
