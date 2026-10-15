import CoreLocation
import Foundation
import Observation

/// Where the person is, for finding restaurants nearby. Asks for When In Use permission the
/// first time and takes one location fix; remembers the last place searched so the next
/// search can start there even when location is off.
@MainActor
@Observable
final class PlanLocationProvider: NSObject, CLLocationManagerDelegate {
    private(set) var authorization: CLAuthorizationStatus = .notDetermined

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var authorizationWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var locationWaiters: [CheckedContinuation<CLLocationCoordinate2D?, Never>] = []

    private static let latitudeKey = "plan.dineOut.lastLatitude"
    private static let longitudeKey = "plan.dineOut.lastLongitude"

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        authorization = manager.authorizationStatus
    }

    var isDenied: Bool { authorization == .denied || authorization == .restricted }
    var isAuthorized: Bool { authorization == .authorizedWhenInUse || authorization == .authorizedAlways }

    /// The last place a restaurant search was centered on.
    static var lastKnown: CLLocationCoordinate2D? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: latitudeKey) != nil else { return nil }
        return CLLocationCoordinate2D(latitude: defaults.double(forKey: latitudeKey), longitude: defaults.double(forKey: longitudeKey))
    }

    static func remember(_ coordinate: CLLocationCoordinate2D) {
        UserDefaults.standard.set(coordinate.latitude, forKey: latitudeKey)
        UserDefaults.standard.set(coordinate.longitude, forKey: longitudeKey)
    }

    /// One location fix, asking for permission first if it hasn't been asked. Nil when
    /// location is off or can't be found.
    func locate() async -> CLLocationCoordinate2D? {
        if authorization == .notDetermined {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                authorizationWaiters.append(continuation)
                manager.requestWhenInUseAuthorization()
            }
        }
        guard isAuthorized else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<CLLocationCoordinate2D?, Never>) in
            locationWaiters.append(continuation)
            if locationWaiters.count == 1 {
                manager.requestLocation()
            }
        }
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.authorizationChanged(status) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let coordinate = locations.last?.coordinate
        Task { @MainActor in self.finish(coordinate) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        Task { @MainActor in self.finish(nil) }
    }

    private func authorizationChanged(_ status: CLAuthorizationStatus) {
        authorization = status
        guard status != .notDetermined else { return }
        let waiters = authorizationWaiters
        authorizationWaiters = []
        waiters.forEach { $0.resume() }
    }

    private func finish(_ coordinate: CLLocationCoordinate2D?) {
        let waiters = locationWaiters
        locationWaiters = []
        waiters.forEach { $0.resume(returning: coordinate) }
    }
}
