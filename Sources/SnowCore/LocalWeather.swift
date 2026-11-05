import Foundation

/// Current conditions at the user's location, reduced to what the snowfall needs.
/// Rates are normalised to one hour so they read like a forecast ("1.2 cm/h").
public struct WeatherReading: Equatable, Sendable {
    /// Fresh snow, in centimetres per hour.
    public var snowfallPerHour: Float
    /// All precipitation (rain, sleet and snow as water), in millimetres per hour.
    public var precipitationPerHour: Float
    /// WMO weather interpretation code, as reported by Open-Meteo.
    public var weatherCode: Int
    /// Air temperature at 2 m, in °C.
    public var temperature: Float

    public init(snowfallPerHour: Float, precipitationPerHour: Float, weatherCode: Int, temperature: Float) {
        self.snowfallPerHour = snowfallPerHour.isFinite ? max(0, snowfallPerHour) : 0
        self.precipitationPerHour = precipitationPerHour.isFinite ? max(0, precipitationPerHour) : 0
        self.weatherCode = weatherCode
        self.temperature = temperature.isFinite ? temperature : 0
    }

    /// WMO codes 71–77 and 85–86 are snow. Snow grains (77) are a dusting at most.
    public var reportsSnow: Bool { (71...77).contains(weatherCode) || weatherCode == 85 || weatherCode == 86 }

    public var isSnowing: Bool { snowDensity > 0 }

    /// Snowfall density matching the simulation's presets: Light 0.55, Steady 1, Flurry 1.65.
    ///
    /// The measured snowfall rate drives the density. Meteorological services call
    /// under ~0.5 cm/h light, ~1.5 cm/h moderate and 3+ cm/h heavy; those map onto
    /// Light, Steady and Flurry, with a little headroom above for real blizzards.
    /// When the model reports a snow weather code but rounds the amount to zero,
    /// the code sets a floor so a visible light snow still falls.
    public var snowDensity: Float {
        var rate = snowfallPerHour
        // Sleet below freezing can be reported as precipitation without a snowfall amount.
        if rate == 0, reportsSnow, temperature <= 1 {
            rate = precipitationPerHour * 0.7  // ~1 mm water ≈ 0.7 cm fresh snow
        }
        let fromRate = Self.interpolate(rate)
        let fromCode: Float = switch weatherCode {
        case 77: 0.25
        case 71, 85: 0.4
        case 73: 0.9
        case 75, 86: 1.5
        default: 0
        }
        return min(Self.maximumDensity, max(fromRate, fromCode))
    }

    public static let maximumDensity: Float = 2

    private static let curve: [(rate: Float, density: Float)] = [
        (0, 0), (0.05, 0.2), (0.5, 0.55), (1.5, 1), (3, 1.65), (6, maximumDensity)
    ]

    static func interpolate(_ rate: Float) -> Float {
        guard rate.isFinite, rate > 0 else { return 0 }
        for (lower, upper) in zip(curve, curve.dropFirst()) where rate <= upper.rate {
            let t = (rate - lower.rate) / (upper.rate - lower.rate)
            return lower.density + (upper.density - lower.density) * t
        }
        return maximumDensity
    }
}

/// Builds and reads Open-Meteo requests (https://open-meteo.com — free, no API key).
public enum OpenMeteo {
    public static func currentConditionsURL(latitude: Double, longitude: Double) -> URL? {
        guard latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        // Round to ~1 km; the forecast grid is coarser than that and it keeps the request less precise.
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.2f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.2f", longitude)),
            URLQueryItem(name: "current", value: "snowfall,precipitation,weather_code,temperature_2m"),
            URLQueryItem(name: "timezone", value: "auto")
        ]
        return components?.url
    }

    private struct Response: Decodable {
        struct Current: Decodable {
            var interval: Double?
            var snowfall: Double?
            var precipitation: Double?
            var weather_code: Int?
            var temperature_2m: Double?
        }
        var current: Current
    }

    /// Current sums cover the preceding `interval` seconds (15 minutes on Open-Meteo),
    /// so they are scaled to an hourly rate.
    public static func decode(_ data: Data) throws -> WeatherReading {
        let current = try JSONDecoder().decode(Response.self, from: data).current
        let interval = current.interval.flatMap { $0 > 0 && $0.isFinite ? $0 : nil } ?? 3600
        let perHour = Float(3600 / min(3600, max(60, interval)))
        return WeatherReading(snowfallPerHour: Float(current.snowfall ?? 0) * perHour,
                              precipitationPerHour: Float(current.precipitation ?? 0) * perHour,
                              weatherCode: current.weather_code ?? 0,
                              temperature: Float(current.temperature_2m ?? 0))
    }
}
