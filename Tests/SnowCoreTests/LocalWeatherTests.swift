import XCTest
@testable import SnowCore

final class LocalWeatherTests: XCTestCase {
    private func reading(snow: Float = 0, precipitation: Float = 0, code: Int = 0, temperature: Float = -3) -> WeatherReading {
        WeatherReading(snowfallPerHour: snow, precipitationPerHour: precipitation, weatherCode: code, temperature: temperature)
    }

    func testNoSnowMeansNoSnowfall() {
        XCTAssertEqual(reading().snowDensity, 0)
        XCTAssertFalse(reading().isSnowing)
        // Rain doesn't snow, however heavy.
        XCTAssertEqual(reading(precipitation: 8, code: 65, temperature: 6).snowDensity, 0)
    }

    func testRatesMatchPresets() {
        XCTAssertEqual(reading(snow: 0.5).snowDensity, Snowfall.light.density, accuracy: 0.001)
        XCTAssertEqual(reading(snow: 1.5).snowDensity, Snowfall.steady.density, accuracy: 0.001)
        XCTAssertEqual(reading(snow: 3).snowDensity, Snowfall.flurry.density, accuracy: 0.001)
        XCTAssertEqual(reading(snow: 40).snowDensity, WeatherReading.maximumDensity)
    }

    func testDensityGrowsWithSnowfall() {
        var previous: Float = 0
        for rate in stride(from: Float(0.01), through: 6, by: 0.05) {
            let density = reading(snow: rate).snowDensity
            XCTAssertGreaterThanOrEqual(density, previous)
            previous = density
        }
    }

    func testSnowCodeGivesAFloorWhenAmountRoundsToZero() {
        XCTAssertGreaterThan(reading(code: 71).snowDensity, 0)
        XCTAssertGreaterThan(reading(code: 75).snowDensity, reading(code: 71).snowDensity)
        // Sleet below freezing: use precipitation as water equivalent.
        XCTAssertEqual(reading(precipitation: 2, code: 73, temperature: 0).snowDensity,
                       WeatherReading.interpolate(1.4), accuracy: 0.001)
    }

    func testBadValuesAreSafe() {
        XCTAssertEqual(reading(snow: .nan).snowDensity, 0)
        XCTAssertEqual(reading(snow: -2).snowDensity, 0)
        XCTAssertNil(OpenMeteo.currentConditionsURL(latitude: .nan, longitude: 0))
        XCTAssertNil(OpenMeteo.currentConditionsURL(latitude: 91, longitude: 0))
    }

    func testURLRoundsCoordinates() throws {
        let url = try XCTUnwrap(OpenMeteo.currentConditionsURL(latitude: 59.334591, longitude: 18.063240))
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "latitude" }?.value, "59.33")
        XCTAssertEqual(query.first { $0.name == "longitude" }?.value, "18.06")
        XCTAssertEqual(url.host, "api.open-meteo.com")
    }

    func testDecodeScalesQuarterHourToHourlyRate() throws {
        let json = """
        {"latitude":59.34,"longitude":18.06,"current_units":{"snowfall":"cm"},
         "current":{"time":"2026-01-10T08:00","interval":900,"snowfall":0.35,"precipitation":0.5,
                    "weather_code":73,"temperature_2m":-4.2}}
        """
        let reading = try OpenMeteo.decode(Data(json.utf8))
        XCTAssertEqual(reading.snowfallPerHour, 1.4, accuracy: 0.001)
        XCTAssertEqual(reading.precipitationPerHour, 2, accuracy: 0.001)
        XCTAssertEqual(reading.weatherCode, 73)
        XCTAssertEqual(reading.temperature, -4.2, accuracy: 0.001)
        XCTAssertTrue(reading.isSnowing)
    }

    func testSimulationFollowsWeatherDensity() {
        let simulation = SnowSimulation(size: SIMD2(400, 300), budget: SimulationBudget(flakes: 100))
        simulation.snowfall = .flurry
        simulation.weatherDensity = 0
        XCTAssertEqual(simulation.snowDensity, 0)
        simulation.weatherDensity = .nan
        XCTAssertEqual(simulation.snowDensity, 0)
        simulation.weatherDensity = nil
        XCTAssertEqual(simulation.snowDensity, Snowfall.flurry.density)
    }
}
