import CoreLocation
import Foundation

/// Location keep-alive, ALWAYS on between Start and Stop (together with the
/// silent audio). Tested on device: with audio-only keep-alive the app keeps
/// running but iOS does NOT apply background Live Activity updates; with
/// location keep-alive every background update is applied. Do not remove.
///
/// - "When In Use" permission is enough: updates are started in the
///   foreground, `allowsBackgroundLocationUpdates = true` +
///   `CLBackgroundActivitySession` (iOS 17) keep them going after locking.
/// - Requires `location` in UIBackgroundModes (project.yml).
/// - Shows the blue location indicator in the status bar while active.
@MainActor
final class LocationKeepAlive: NSObject {
    var onLog: (String) -> Void = { _ in }

    private let manager = CLLocationManager()
    private var backgroundSession: CLBackgroundActivitySession?
    private(set) var isActive = false
    private var updateCount = 0
    private var lastUpdateLog = Date.distantPast

    /// With "Always" permission, updates can also be started while the app is
    /// in the background (e.g. from the Shortcuts automation).
    var canStartInBackground: Bool { manager.authorizationStatus == .authorizedAlways }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .automotiveNavigation
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        updateCount = 0
        let status = manager.authorizationStatus
        onLog("Location: start (auth=\(Self.name(status)))")
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
            return // continues in locationManagerDidChangeAuthorization
        }
        beginUpdates()
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        backgroundSession?.invalidate()
        backgroundSession = nil
        onLog("Location: stopped after \(updateCount) update(s)")
    }

    private func beginUpdates() {
        let status = manager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            onLog("Location: NOT authorized (\(Self.name(status))) — allow location for CarLyrics in Settings")
            return
        }
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        if backgroundSession == nil { backgroundSession = CLBackgroundActivitySession() }
        manager.startUpdatingLocation()
        onLog("Location: updates started (accuracy 3km, no auto-pause, background allowed)")
    }

    private func didUpdate(count: Int) {
        updateCount += count
        if Date().timeIntervalSince(lastUpdateLog) > 60 {
            lastUpdateLog = Date()
            onLog("Location: \(updateCount) update(s) so far")
        }
    }

    private func authChanged(_ status: CLAuthorizationStatus) {
        onLog("Location: authorization -> \(Self.name(status))")
        if isActive { beginUpdates() }
    }

    static func name(_ s: CLAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorizedAlways: return "always"
        case .authorizedWhenInUse: return "whenInUse"
        @unknown default: return "unknown"
        }
    }
}

extension LocationKeepAlive: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let n = locations.count
        Task { @MainActor in self.didUpdate(count: n) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let msg = error.localizedDescription
        Task { @MainActor in self.onLog("Location: error \(msg)") }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.authChanged(status) }
    }

    nonisolated func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        Task { @MainActor in self.onLog("Location: updates PAUSED by system") }
    }

    nonisolated func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        Task { @MainActor in self.onLog("Location: updates resumed") }
    }
}
