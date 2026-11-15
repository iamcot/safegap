// Tốc độ xe mình từ GPS (CoreLocation, kCLLocationAccuracyBestForNavigation).
import CoreLocation
import Foundation

final class SpeedProvider: NSObject, CLLocationManagerDelegate {
    struct Reading {
        let kmh: Double
        let accuracyKmh: Double?
        let at: Date
    }

    private let manager = CLLocationManager()
    private let lock = NSLock()
    private var last: Reading?
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)?

    /// Tạo trên main thread (CLLocationManager cần run loop).
    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .automotiveNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
    }

    func start() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    func stop() { manager.stopUpdatingLocation() }

    /// Đọc được từ mọi thread. nil nếu chưa có hoặc quá cũ (mất GPS trong hầm...).
    func current(maxAge: TimeInterval = 3.0, now: Date = Date()) -> Reading? {
        lock.lock()
        defer { lock.unlock() }
        guard let r = last, now.timeIntervalSince(r.at) <= maxAge else { return nil }
        return r
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last, l.speed >= 0 else { return }
        let acc = l.speedAccuracy >= 0 ? l.speedAccuracy * 3.6 : nil
        let r = Reading(kmh: l.speed * 3.6, accuracyKmh: acc, at: Date())
        lock.lock()
        last = r
        lock.unlock()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorizationChange?(manager.authorizationStatus)
    }
}
