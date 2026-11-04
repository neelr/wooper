import Foundation
import CoreLocation

@main struct StandbyForecastTests {
    static func main() throws {
        let decoder = JSONDecoder()
        let tideJSON = #"{"predictions":[{"t":"2026-11-04 02:43","v":"4.827","type":"H"},{"t":"2026-11-04 09:00","v":"0.471","type":"L"},{"t":"2026-11-04 21:59","v":"1.352","type":"L"}]}"#
        let tides = try decoder.decode(StandbyTides.self, from: Data(tideJSON.utf8))
        let iso = ISO8601DateFormatter()
        assert(tides.nextLow(after: iso.date(from: "2026-11-04T08:00:00Z")!)?.t == "2026-11-04 09:00")
        assert(tides.nextLow(after: iso.date(from: "2026-11-04T09:01:00Z")!)?.t == "2026-11-04 21:59")
        assert(tides.nextLow(after: iso.date(from: "2026-11-05T09:01:00Z")!) == nil)
        let start = Date(timeIntervalSince1970: 1793781000)
        let weather = StandbyWeather(current: .init(temperature_2m: 55, apparent_temperature: 52, weather_code: 45, wind_speed_10m: 10, wind_gusts_10m: 15, is_day: 1), daily: .init(time: [], temperature_2m_max: [], temperature_2m_min: [], sunset: []), minutely_15: .init(time: [start.timeIntervalSince1970, start.timeIntervalSince1970 + 900, start.timeIntervalSince1970 + 1800], precipitation: [0, 0, 1]))
        assert(weather.rainSummary(now: start) == "rain in ~15 min")
        assert(weather.rainSummary(now: start.addingTimeInterval(300)) == "rain in ~10 min",
               "Count down to the start of the wet interval, not its end")
        assert(weather.rainSummary(now: start.addingTimeInterval(86400)) == nil, "Do not display expired rain timing")
        assert(weather.symbol == "cloud.fog")
        func rainForecast(_ amounts: [Double?], offsets: [Double]? = nil) -> StandbyWeather {
            let offsets = offsets ?? amounts.indices.map { Double($0) * 900 }
            return StandbyWeather(current: weather.current, daily: weather.daily,
                minutely_15: .init(time: offsets.map { start.timeIntervalSince1970 + $0 }, precipitation: amounts))
        }
        assert(rainForecast([0, 1, 0]).rainSummary(now: start.addingTimeInterval(300)) == "rain easing in ~10 min")
        assert(rainForecast([0, 1, 1]).rainSummary(now: start) == "rain continuing")
        assert(rainForecast(Array(repeating: 0, count: 9)).rainSummary(now: start) == nil, "Hide the rain line when the forecast is dry")
        assert(rainForecast([1, 0, 0]).rainSummary(now: start) == nil,
               "Rain in an elapsed interval must not be described as ongoing")
        assert(rainForecast([0, nil, 1]).rainSummary(now: start) == nil, "Missing current coverage is not dry weather")
        assert(rainForecast([0, 1], offsets: [900, 2700]).rainSummary(now: start) == nil,
               "Do not predict across a gap in the forecast")
        let freeJSON = #"{"bikes":[{"bike_id":"regular","lat":37.7,"lon":-122.4,"is_reserved":0,"is_disabled":0,"type":"classic_bike"},{"bike_id":"electric","lat":37.7,"lon":-122.4,"is_reserved":0,"is_disabled":0,"type":"electric_bike"}]}"#
        let types = try decoder.decode(FreeBikes.self, from: Data(freeJSON.utf8))
        assert(!types.bikes[0].electric && types.bikes[1].electric, "Parked regular bikes must not appear as e-bikes")
        let southPark = CLLocationCoordinate2D(latitude: 37.7815, longitude: -122.3945)
        func bike(_ id: String, lat: Double, total: Int, electric: Int, docks: Int?) -> StandbyBike {
            StandbyBike(id: id, name: id, coordinate: .init(latitude: lat, longitude: -122.3945),
                total: total, electric: electric, docks: docks, reported: start, rentalURL: nil)
        }
        let markers = [
            bike("empty station", lat: 37.782, total: 0, electric: 0, docks: 20),
            bike("regular station", lat: 37.783, total: 12, electric: 0, docks: 8),
            bike("parked regular", lat: 37.781, total: 1, electric: 0, docks: nil),
            bike("outside map", lat: 37.8, total: 5, electric: 5, docks: 5)
        ]
        let visible = StandbyBike.inViewport(markers, center: southPark, latitudeSpan: 0.01, longitudeSpan: 0.01, electricOnly: false)
        assert(Set(visible.map(\.id)) == Set(["empty station", "regular station", "parked regular"]))
        let electric = StandbyBike.inViewport(markers, center: southPark, latitudeSpan: 0.01, longitudeSpan: 0.01, electricOnly: true)
        assert(Set(electric.map(\.id)) == Set(["empty station", "regular station"]), "Zero-e-bike stations stay visible; parked regular bikes do not")
        let panned = StandbyBike.inViewport(markers, center: .init(latitude: 37.8, longitude: -122.3945), latitudeSpan: 0.005, longitudeSpan: 0.005, electricOnly: false)
        assert(panned.map(\.id) == ["outside map"], "Panning must load the new area's pins")
        let nearest = StandbyBike.nearestAvailable(markers, center: southPark, electricOnly: false)
        assert(nearest.first?.id == "parked regular")
        assert(!nearest.contains { $0.id == "empty station" }, "An empty station must not set the initial camera radius")
        let busyArea = (0..<5000).reversed().map { index in
            bike("busy-\(index)", lat: southPark.latitude + Double(index) * 0.00001, total: 1, electric: 1, docks: 10)
        }
        let busyViewport = StandbyBike.inViewport(busyArea, center: southPark, latitudeSpan: 0.2, longitudeSpan: 0.2, electricOnly: false)
        assert(busyViewport.count == 120, "A large feed must keep the marker cap")
        assert(busyViewport.map(\.id) == (0..<120).map { "busy-\($0)" }, "Select the closest markers even when the feed arrives farthest-first")
        let nearestBusy = StandbyBike.nearestAvailable(busyArea, center: southPark, electricOnly: true)
        assert(nearestBusy.map(\.id) == (0..<6).map { "busy-\($0)" })
        // Optional live payloads verify the provider schemas as well as our deterministic cases.
        if CommandLine.arguments.count > 1 {
            let directory = CommandLine.arguments[1]
            func read(_ file: String) throws -> Data { try Data(contentsOf: URL(fileURLWithPath: directory + "/" + file)) }
            let live = try decoder.decode(StandbyWeather.self, from: read("standby-weather.json"))
            assert(!live.daily.sunset.isEmpty)
            let status = try decoder.decode(BikeFeed<BikeStatus>.self, from: read("bay-station_status.json"))
            let information = try decoder.decode(BikeFeed<BikeInformation>.self, from: read("bay-station_information.json"))
            let free = try decoder.decode(BikeFeed<FreeBikes>.self, from: read("bay-free_bike_status.json"))
            assert(!status.data.stations.isEmpty && !information.data.stations.isEmpty && !free.data.bikes.isEmpty)
        }
        print("PASS UTC tide selection, expired forecasts, rain timing, viewport panning, empty stations, and provider response decoding")
    }
}
