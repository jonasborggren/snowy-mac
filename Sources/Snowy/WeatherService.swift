import CoreLocation
import Foundation
import SnowCore

/// Finds the Mac's approximate location and polls Open-Meteo for current snowfall.
/// Only rounded coordinates leave the machine, and only while Local Weather is on.
@MainActor
final class WeatherService: NSObject, CLLocationManagerDelegate {
    enum Status: Equatable {
        case idle
        case locating
        case locationDenied
        case unavailable(String)
        case reading(WeatherReading)
    }

    var onChange: ((Status) -> Void)?
    private(set) var status: Status = .idle {
        didSet { if status != oldValue { onChange?(status) } }
    }

    private let manager = CLLocationManager()
    private var coordinate: CLLocationCoordinate2D?
    private var timer: Timer?
    private var fetch: Task<Void, Never>?
    private var running = false
    /// Open-Meteo's current values update every 15 minutes.
    private let refreshInterval: TimeInterval = 15 * 60

    override init() {
        super.init()
        manager.delegate = self
        // A city-level fix is plenty for weather and is quicker and kinder to the battery.
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
    }

    func start() {
        guard !running else { return }
        running = true
        status = .locating
        handleAuthorization(manager.authorizationStatus)
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        running = false
        timer?.invalidate()
        timer = nil
        fetch?.cancel()
        fetch = nil
        manager.stopUpdatingLocation()
        status = .idle
    }

    /// Re-reads location (it may have changed since the last poll) and then the weather.
    func refresh() {
        guard running else { return }
        handleAuthorization(manager.authorizationStatus)
    }

    private func handleAuthorization(_ authorization: CLAuthorizationStatus) {
        guard running else { return }
        switch authorization {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            status = .locationDenied
        default:
            manager.requestLocation()
        }
    }

    private func fetchWeather(at coordinate: CLLocationCoordinate2D) {
        guard let url = OpenMeteo.currentConditionsURL(latitude: coordinate.latitude,
                                                       longitude: coordinate.longitude) else {
            status = .unavailable("Location is invalid")
            return
        }
        fetch?.cancel()
        fetch = Task { [weak self] in
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.setValue("Snowy (desktop snow)", forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard !Task.isCancelled, let self, self.running else { return }
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    self.keepLastReadingOr("Weather service returned \(http.statusCode)")
                    return
                }
                self.status = .reading(try OpenMeteo.decode(data))
            } catch {
                guard !Task.isCancelled, let self, self.running else { return }
                self.keepLastReadingOr("Weather is unavailable right now")
            }
        }
    }

    /// A brief network hiccup shouldn't stop snow that is actually falling outside.
    private func keepLastReadingOr(_ message: String) {
        if case .reading = status { return }
        status = .unavailable(message)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let authorization = manager.authorizationStatus
        Task { @MainActor [weak self] in self?.handleAuthorization(authorization) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last?.coordinate else { return }
        Task { @MainActor [weak self] in
            guard let self, self.running else { return }
            self.coordinate = latest
            self.fetchWeather(at: latest)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        let denied = (error as? CLError)?.code == .denied
        Task { @MainActor [weak self] in
            guard let self, self.running else { return }
            if denied {
                self.status = .locationDenied
            } else if let coordinate = self.coordinate {
                // Use the last known position rather than giving up.
                self.fetchWeather(at: coordinate)
            } else {
                self.keepLastReadingOr("Couldn't find your location")
            }
        }
    }
}
