import CoreLocation
import Observation

/// One-shot location for scouts checking a spot on the street. Used only on the phone to find
/// the block you're standing in; never stored or sent anywhere.
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var wantsFix = false
    @ObservationIgnored var onUpdate: ((Coordinate) -> Void)?
    @ObservationIgnored var onDenied: (() -> Void)?
    @ObservationIgnored var onFailure: (() -> Void)?

    private(set) var status: CLAuthorizationStatus = .notDetermined

    var isAuthorized: Bool { status == .authorizedWhenInUse || status == .authorizedAlways }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        status = manager.authorizationStatus
    }

    func locate() {
        switch manager.authorizationStatus {
        case .notDetermined:
            wantsFix = true
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            onDenied?()
        default:
            wantsFix = true
            manager.requestLocation()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        status = manager.authorizationStatus
        guard wantsFix else { return }
        if isAuthorized {
            manager.requestLocation()
        } else if status == .denied || status == .restricted {
            wantsFix = false
            onDenied?()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard wantsFix, let location = locations.last else { return }
        wantsFix = false
        onUpdate?(Coordinate(location.coordinate.latitude, location.coordinate.longitude))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard wantsFix else { return }
        wantsFix = false
        onFailure?()
    }
}
