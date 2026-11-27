import MapKit
import SwiftUI

/// Fallback map with the same layers, used only when no Google Maps API key is set,
/// so the demo never opens on a blank map.
struct AppleSiteMap: View {
    let model: SiteModel
    /// Space taken by the search bar (top) and the sheet (bottom). Camera moves centre their target
    /// in the map that's left, so a selected spot never sits under the sheet.
    let insets: EdgeInsets
    @State private var position: MapCameraPosition = .automatic
    /// Place pins that passed the collision check. nil until the first layout pass.
    @State private var visibleIDs: Set<String>?
    /// Spots that keep their own pin, with how many nearby spots each stands for. nil until laid out.
    @State private var spotGroups: [Int: Int]?
    /// What's on screen, so only those cells are drawn.
    @State private var region: MapRegion?
    @State private var zoom = Double(AreaData.defaultZoom)
    /// Degrees of latitude per screen point at the current zoom, for centring above the sheet.
    @State private var latitudePerPoint: Double?
    /// Set when a camera move happened before the map reported its scale, so it couldn't allow for
    /// the sheet yet (for example a spot opened at launch). Re-centred once the scale is known.
    @State private var needsRecentre = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let selectedBlock: Int? = switch model.selection {
        case .spot(let id), .block(let id): id
        default: nil
        }
        let visibleKinds = Set(model.layers.flatMap(\.kinds))
        let places = model.data.allPlaces.filter { place in
            visibleKinds.contains(place.kind) && (visibleIDs?.contains(place.id) ?? true)
        }
        let highlight = colorScheme == .dark ? PinColor.yellow : PinColor.brown

        GeometryReader { geometry in
            MapReader { proxy in
                Map(position: $position, interactionModes: [.pan, .zoom, .rotate]) {
                    if model.layers.contains(.demand) {
                        ForEach(model.drawCells(in: region?.expanded(by: 0.3), zoom: zoom)) { cell in
                            if let color = DemandScale.color(for: cell.score) {
                                MapPolygon(coordinates: cell.corners.map(\.cl))
                                    .foregroundStyle(color)
                                    .stroke(cell.id.hasPrefix("b") && cell.blockID == selectedBlock ? highlight : .clear,
                                            lineWidth: 2.5)
                            }
                        }
                    }

                    if case .spot(let id) = model.selection, let spot = model.spot(forBlock: id) {
                        MapCircle(center: spot.block.center.cl, radius: 400)
                            .foregroundStyle(PinColor.yellow.opacity(0.12))
                            .stroke(highlight.opacity(0.85), lineWidth: 1.5)
                    }

                    ForEach(places) { place in
                        Annotation(place.name, coordinate: place.coordinate.cl, anchor: .center) {
                            Button { model.open(.place(place.id)) } label: { PinView(kind: place.kind) }
                                .buttonStyle(.plain)
                                .accessibilityLabel(PinStyle.accessibilityLabel(for: place))
                        }
                        .annotationTitles(.hidden)
                    }

                    ForEach(model.spots.filter { spotGroups?[$0.id] != nil || spotGroups == nil }) { spot in
                        let more = spotGroups?[spot.id] ?? 0
                        Annotation(spot.title, coordinate: spot.block.center.cl, anchor: .center) {
                            Button { model.open(.spot(spot.id)) } label: {
                                SpotMapPin(spot: spot, selected: model.selection == .spot(spot.id),
                                           approved: model.decision(for: spot.id)?.isApproved == true, more: more)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(spot.title), score \(spot.block.score)"
                                                + (more > 0 ? ", and \(more) more spots nearby. Zoom in to see them" : ""))
                        }
                        .annotationTitles(.hidden)
                    }

                    if model.location.isAuthorized {
                        UserAnnotation()
                    }
                }
                .mapStyle(.standard(pointsOfInterest: .including([.publicTransport, .park, .university])))
                .mapControls { MapCompass() }
                .onTapGesture { point in
                    guard let coordinate = proxy.convert(point, from: .local) else { return }
                    if zoom < SiteModel.detailZoom,
                       let cell = model.drawCells(in: region, zoom: zoom).first(where: { cell in
                           let lats = cell.corners.map(\.latitude), lons = cell.corners.map(\.longitude)
                           return (lats.min()!...lats.max()!).contains(coordinate.latitude)
                               && (lons.min()!...lons.max()!).contains(coordinate.longitude)
                       }) {
                        // Zoomed out, a cell stands for 9 blocks: open its best block and zoom in.
                        model.open(model.spot(forBlock: cell.blockID) != nil ? .spot(cell.blockID) : .block(cell.blockID))
                    } else {
                        model.tapMap(at: Coordinate(coordinate))
                    }
                }
                .onMapCameraChange(frequency: .onEnd) { context in
                    let span = context.region.span
                    let center = context.region.center
                    region = MapRegion(minLat: center.latitude - span.latitudeDelta / 2,
                                       maxLat: center.latitude + span.latitudeDelta / 2,
                                       minLon: center.longitude - span.longitudeDelta / 2,
                                       maxLon: center.longitude + span.longitudeDelta / 2)
                    // Inverse of `move(to:)`: camera height back to an approximate Google zoom level.
                    zoom = 15 - log2(max(context.camera.distance, 1) / 9500)
                    if geometry.size.height > 0 { latitudePerPoint = span.latitudeDelta / geometry.size.height }
                    if needsRecentre, latitudePerPoint != nil {
                        needsRecentre = false
                        move(to: model.cameraRequest, animated: false)
                    }
                    layoutPins(proxy: proxy, size: geometry.size)
                }
                .onChange(of: model.scoreVersion) { _, _ in layoutPins(proxy: proxy, size: geometry.size) }
                .onChange(of: model.layers) { _, _ in layoutPins(proxy: proxy, size: geometry.size) }
                .onChange(of: model.selection) { _, _ in layoutPins(proxy: proxy, size: geometry.size) }
            }
        }
        .onAppear { move(to: model.cameraRequest, animated: false) }
        .onChange(of: model.cameraRequest) { _, request in move(to: request, animated: true) }
    }

    /// The same collision pass as the Google map: priority order, no overlaps.
    private func layoutPins(proxy: MapProxy, size: CGSize) {
        let visibleKinds = Set(model.layers.flatMap(\.kinds))
        let candidates = model.data.allPlaces
            .filter { visibleKinds.contains($0.kind) }
            .compactMap { place -> PinLayout.Candidate? in
                guard let point = proxy.convert(place.coordinate.cl, to: .local) else { return nil }
                return PinLayout.Candidate(id: place.id, kind: place.kind, point: point)
            }
        let spotPoints = model.spots.compactMap { spot in
            proxy.convert(spot.block.center.cl, to: .local).map { (id: spot.id, point: $0) }
        }
        var selectedSpot: Int?
        if case .spot(let id) = model.selection { selectedSpot = id }
        let groups = PinLayout.groupSpots(spotPoints, keep: selectedSpot)
        if groups != spotGroups { spotGroups = groups }
        let reserved = spotPoints
            .filter { groups[$0.id] != nil }
            .flatMap { [$0.point, CGPoint(x: $0.point.x + 30, y: $0.point.y)] }
        var alwaysShow: Set<String> = []
        if case .place(let id) = model.selection { alwaysShow.insert(id) }

        let result = PinLayout.visible(candidates, reserved: reserved, bounds: CGRect(origin: .zero, size: size),
                                       alwaysShow: alwaysShow)
        visibleIDs = result.visible
        if model.hiddenPinCount != result.hiddenOnScreen { model.hiddenPinCount = result.hiddenOnScreen }
    }

    private func move(to request: CameraRequest, animated: Bool) {
        // Google zoom 15 is roughly a 2.5 km wide view (camera height about 9.5 km); each zoom step halves it.
        let distance = 9500 * pow(2, Double(15 - request.zoom))
        var center = request.center
        if let latitudePerPoint {
            // Aim the camera below the target so the target lands mid-way between the search bar
            // and the top of the sheet. Each zoom step halves the degrees per point.
            let perPoint = latitudePerPoint * pow(2, zoom - Double(request.zoom))
            center = Coordinate(center.latitude - Double(insets.bottom - insets.top) / 2 * perPoint, center.longitude)
        } else if insets.bottom != insets.top {
            needsRecentre = true
        }
        let camera = MapCameraPosition.camera(MapCamera(centerCoordinate: center.cl, distance: distance))
        if animated {
            withAnimation(.easeInOut(duration: 0.6)) { position = camera }
        } else {
            position = camera
        }
    }
}
