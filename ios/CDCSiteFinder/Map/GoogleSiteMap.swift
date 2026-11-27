import GoogleMaps
import SwiftUI

/// The map, drawn with the Google Maps SDK for iOS.
///
/// SwiftUI passes in the few values that should trigger a redraw; the coordinator then updates
/// only the overlays that changed, and re-runs the pin collision pass whenever the camera stops.
struct GoogleSiteMap: UIViewRepresentable {
    let model: SiteModel
    let scoreVersion: Int
    let layers: Set<MapLayer>
    let selection: Route?
    let camera: CameraRequest
    let showsUserLocation: Bool
    let padding: UIEdgeInsets

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> GMSMapView {
        let options = GMSMapViewOptions()
        options.camera = GMSCameraPosition(latitude: camera.center.latitude, longitude: camera.center.longitude,
                                           zoom: camera.zoom)
        let map = GMSMapView(options: options)
        map.delegate = context.coordinator
        map.settings.compassButton = true
        map.settings.rotateGestures = true
        map.settings.tiltGestures = false
        map.isBuildingsEnabled = false
        // 9.5 fits all of Hong Kong, Lantau included; below 13 the demand layer switches to 3×3 groups.
        map.setMinZoom(9.5, maxZoom: 19)
        // Lets VoiceOver read markers, using each marker's title and snippet.
        map.accessibilityElementsHidden = false
        context.coordinator.attach(to: map)
        return map
    }

    func updateUIView(_ map: GMSMapView, context: Context) {
        map.padding = padding
        map.isMyLocationEnabled = showsUserLocation
        context.coordinator.sync(map: map, scoreVersion: scoreVersion, layers: layers, selection: selection,
                                 camera: camera, dark: context.environment.colorScheme == .dark)
    }

    final class Coordinator: NSObject, GMSMapViewDelegate {
        let model: SiteModel
        private var polygons: [String: GMSPolygon] = [:]
        private var placeMarkers: [String: GMSMarker] = [:]
        private var spotMarkers: [Int: GMSMarker] = [:]
        private var catchment: GMSCircle?

        private var drawnVersion = -1
        private var drawnLayers: Set<MapLayer> = []
        private var drawnSelection: Route?
        private var drawnCamera: UUID?
        private var drawnDark: Bool?

        init(model: SiteModel) { self.model = model }

        func attach(to map: GMSMapView) {
            drawnCamera = model.cameraRequest.id
        }

        func sync(map: GMSMapView, scoreVersion: Int, layers: Set<MapLayer>, selection: Route?,
                  camera: CameraRequest, dark: Bool) {
            let styleChanged = dark != drawnDark
            if styleChanged {
                map.mapStyle = try? GMSMapStyle(jsonString: dark ? GoogleMapStyle.night : GoogleMapStyle.day)
                drawnDark = dark
            }

            let scoresChanged = scoreVersion != drawnVersion
            if scoresChanged || styleChanged || layers != drawnLayers || selection != drawnSelection {
                if scoresChanged { syncPlaceMarkers() }
                drawDemand(on: map, show: layers.contains(.demand), selection: selection, dark: dark)
                drawSpots(on: map, selection: selection, dark: dark)
                drawnVersion = scoreVersion
                drawnLayers = layers
                drawnSelection = selection
                layoutPins(on: map)
            }

            if camera.id != drawnCamera {
                drawnCamera = camera.id
                map.animate(to: GMSCameraPosition(target: camera.center.cl, zoom: camera.zoom))
            }
        }

        // MARK: Demand blocks

        private func selectedBlockID(_ selection: Route?) -> Int? {
            switch selection {
            case .spot(let id), .block(let id): id
            default: nil
            }
        }

        /// Draws only the cells on screen: 3×3 groups when zoomed out, single blocks when zoomed in.
        private func drawDemand(on map: GMSMapView, show: Bool, selection: Route?, dark: Bool) {
            let selectedID = selectedBlockID(selection)
            let bounds = GMSCoordinateBounds(region: map.projection.visibleRegion())
            let region = MapRegion(minLat: bounds.southWest.latitude, maxLat: bounds.northEast.latitude,
                                   minLon: bounds.southWest.longitude, maxLon: bounds.northEast.longitude)
                .expanded(by: 0.3)
            let cells = show ? model.drawCells(in: region, zoom: Double(map.camera.zoom)) : []
            let wanted = Set(cells.map(\.id))
            for (key, polygon) in polygons where !wanted.contains(key) {
                polygon.map = nil
                polygons[key] = nil
            }
            for cell in cells {
                guard let color = DemandScale.uiColor(for: cell.score) else { continue }
                let polygon = polygons[cell.id] ?? makePolygon(for: cell)
                polygon.fillColor = color
                let selected = cell.id.hasPrefix("b") && cell.blockID == selectedID
                polygon.strokeWidth = selected ? 2.5 : 0
                polygon.strokeColor = dark ? UIColor(hex: 0xF7B500) : UIColor(hex: 0x4A2511)
                polygon.zIndex = selected ? 2 : 1
                if polygon.map == nil { polygon.map = map }
            }
        }

        private func makePolygon(for cell: DrawCell) -> GMSPolygon {
            let path = GMSMutablePath()
            for corner in cell.corners { path.add(corner.cl) }
            let polygon = GMSPolygon(path: path)
            polygon.isTappable = true
            polygon.userData = cell.blockID
            polygons[cell.id] = polygon
            return polygon
        }

        // MARK: Place pins

        /// Keeps one marker per place, adding and removing markers when approved edits change the data.
        private func syncPlaceMarkers() {
            let places = model.data.allPlaces
            let ids = Set(places.map(\.id))
            for (id, marker) in placeMarkers where !ids.contains(id) {
                marker.map = nil
                placeMarkers[id] = nil
            }
            for place in places {
                let marker = placeMarkers[place.id] ?? GMSMarker(position: place.coordinate.cl)
                marker.position = place.coordinate.cl
                marker.icon = PinRenderer.image(for: place.kind)
                marker.groundAnchor = CGPoint(x: 0.5, y: 0.5)
                marker.title = PinStyle.accessibilityLabel(for: place)
                marker.tracksViewChanges = false
                marker.zIndex = Int32(20 - place.kind.priority)
                marker.userData = Route.place(place.id)
                placeMarkers[place.id] = marker
            }
        }

        /// The collision pass: show pins in priority order and hide any that would overlap.
        private func layoutPins(on map: GMSMapView) {
            let visibleKinds = Set(drawnLayers.flatMap(\.kinds))
            var candidates: [PinLayout.Candidate] = []
            for (id, marker) in placeMarkers {
                guard let place = model.place(id), visibleKinds.contains(place.kind) else { continue }
                candidates.append(PinLayout.Candidate(id: id, kind: place.kind,
                                                      point: map.projection.point(for: marker.position)))
            }
            // Spots first: pins that would overlap fold into the best-ranked one, which shows "+N".
            let spotPoints = model.spots.compactMap { spot in
                spotMarkers[spot.id].map { (id: spot.id, point: map.projection.point(for: $0.position)) }
            }
            var selectedSpot: Int?
            if case .spot(let id) = drawnSelection { selectedSpot = id }
            let groups = PinLayout.groupSpots(spotPoints, keep: selectedSpot)
            for spot in model.spots {
                guard let marker = spotMarkers[spot.id] else { continue }
                guard let more = groups[spot.id] else {
                    if marker.map != nil { marker.map = nil }
                    continue
                }
                let rendered = PinRenderer.spotImage(letter: spot.letter, score: spot.block.score,
                                                     selected: drawnSelection == .spot(spot.id),
                                                     approved: model.decision(for: spot.id)?.isApproved == true,
                                                     more: more)
                if marker.icon !== rendered.image {
                    marker.icon = rendered.image
                    marker.groundAnchor = CGPoint(x: rendered.anchorX, y: 0.5)
                    marker.title = "\(spot.title), score \(spot.block.score)"
                        + (more > 0 ? ", and \(more) more spots nearby. Zoom in to see them" : "")
                }
                if marker.map == nil { marker.map = map }
            }

            var reserved: [CGPoint] = []
            for (id, point) in spotPoints where groups[id] != nil {
                reserved += [point, CGPoint(x: point.x + 30, y: point.y)]
            }
            var alwaysShow: Set<String> = []
            if case .place(let id) = drawnSelection { alwaysShow.insert(id) }

            let result = PinLayout.visible(candidates, reserved: reserved, bounds: map.bounds, alwaysShow: alwaysShow)
            for (id, marker) in placeMarkers {
                let show = result.visible.contains(id)
                if show, marker.map == nil { marker.map = map }
                if !show, marker.map != nil { marker.map = nil }
            }
            let hidden = result.hiddenOnScreen
            DispatchQueue.main.async { [model] in
                if model.hiddenPinCount != hidden { model.hiddenPinCount = hidden }
            }
        }

        // MARK: Spots

        private func drawSpots(on map: GMSMapView, selection: Route?, dark: Bool) {
            spotMarkers.values.forEach { $0.map = nil }
            spotMarkers = [:]
            for spot in model.spots {
                let selected = selection == .spot(spot.id)
                let approved = model.decision(for: spot.id)?.isApproved == true
                let rendered = PinRenderer.spotImage(letter: spot.letter, score: spot.block.score,
                                                     selected: selected, approved: approved)
                let marker = GMSMarker(position: spot.block.center.cl)
                marker.icon = rendered.image
                marker.groundAnchor = CGPoint(x: rendered.anchorX, y: 0.5)
                marker.title = "\(spot.title), score \(spot.block.score)"
                marker.snippet = "About \(Int(spot.block.netOrders.rounded())) new orders a day. \(model.directions(to: spot.block.center).short)."
                marker.zIndex = selected ? 40 : 30
                marker.tracksViewChanges = false
                marker.userData = Route.spot(spot.id)
                marker.map = map
                spotMarkers[spot.id] = marker
            }

            catchment?.map = nil
            catchment = nil
            if case .spot(let id) = selection, let spot = model.spot(forBlock: id) {
                let circle = GMSCircle(position: spot.block.center.cl, radius: 400)
                circle.fillColor = UIColor(hex: 0xF7B500, alpha: 0.12)
                circle.strokeColor = dark ? UIColor(hex: 0xF7B500, alpha: 0.9) : UIColor(hex: 0x4A2511, alpha: 0.85)
                circle.strokeWidth = 1.5
                circle.zIndex = 3
                circle.map = map
                catchment = circle
            }
        }

        // MARK: GMSMapViewDelegate

        func mapView(_ mapView: GMSMapView, idleAt position: GMSCameraPosition) {
            drawDemand(on: mapView, show: drawnLayers.contains(.demand), selection: drawnSelection, dark: drawnDark ?? false)
            layoutPins(on: mapView)
        }

        func mapView(_ mapView: GMSMapView, didTap marker: GMSMarker) -> Bool {
            if let route = marker.userData as? Route { model.open(route) }
            return true
        }

        func mapView(_ mapView: GMSMapView, didTap overlay: GMSOverlay) {
            guard let id = overlay.userData as? Int else { return }
            // Zoomed out, a cell stands for 9 blocks: open its best block and zoom in to it.
            let zoomedOut = Double(mapView.camera.zoom) < SiteModel.detailZoom
            model.open(model.spot(forBlock: id) != nil ? .spot(id) : .block(id), moveCamera: zoomedOut)
        }

        func mapView(_ mapView: GMSMapView, didTapAt coordinate: CLLocationCoordinate2D) {
            model.tapMap(at: Coordinate(coordinate))
        }
    }
}

/// Quiet base maps: business pins hidden, roads and land desaturated, transit kept.
/// Follows the "remove what isn't essential" rule so the demand layer and pins carry the story.
enum GoogleMapStyle {
    static let day = """
    [
      { "featureType": "poi", "elementType": "labels.icon", "stylers": [{ "visibility": "off" }] },
      { "featureType": "poi.business", "stylers": [{ "visibility": "off" }] },
      { "featureType": "poi.school", "elementType": "labels", "stylers": [{ "visibility": "off" }] },
      { "featureType": "poi.park", "elementType": "geometry", "stylers": [{ "color": "#dfeccf" }] },
      { "featureType": "landscape", "elementType": "geometry", "stylers": [{ "color": "#f5f3ef" }] },
      { "featureType": "road", "elementType": "geometry", "stylers": [{ "saturation": -100 }, { "lightness": 25 }] },
      { "featureType": "road.highway", "elementType": "geometry", "stylers": [{ "color": "#e6e1d8" }] },
      { "featureType": "road", "elementType": "labels.text.fill", "stylers": [{ "color": "#6f655c" }] },
      { "featureType": "transit.line", "elementType": "geometry", "stylers": [{ "saturation": -60 }, { "lightness": 20 }] },
      { "featureType": "water", "elementType": "geometry", "stylers": [{ "color": "#cfe0ea" }] },
      { "featureType": "administrative", "elementType": "labels.text.fill", "stylers": [{ "color": "#4a2511" }] }
    ]
    """

    static let night = """
    [
      { "elementType": "geometry", "stylers": [{ "color": "#1d1a17" }] },
      { "elementType": "labels.text.fill", "stylers": [{ "color": "#a89c8f" }] },
      { "elementType": "labels.text.stroke", "stylers": [{ "color": "#1d1a17" }] },
      { "featureType": "poi", "elementType": "labels.icon", "stylers": [{ "visibility": "off" }] },
      { "featureType": "poi.business", "stylers": [{ "visibility": "off" }] },
      { "featureType": "poi.school", "elementType": "labels", "stylers": [{ "visibility": "off" }] },
      { "featureType": "poi.park", "elementType": "geometry", "stylers": [{ "color": "#22301f" }] },
      { "featureType": "road", "elementType": "geometry", "stylers": [{ "color": "#38322c" }] },
      { "featureType": "road.highway", "elementType": "geometry", "stylers": [{ "color": "#4a4139" }] },
      { "featureType": "road", "elementType": "labels.text.fill", "stylers": [{ "color": "#b3a89c" }] },
      { "featureType": "transit.line", "elementType": "geometry", "stylers": [{ "color": "#3a3530" }] },
      { "featureType": "water", "elementType": "geometry", "stylers": [{ "color": "#14212b" }] },
      { "featureType": "administrative", "elementType": "labels.text.fill", "stylers": [{ "color": "#e8b07a" }] }
    ]
    """
}
