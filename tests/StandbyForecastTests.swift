import Foundation

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
        let weather = StandbyWeather(current: .init(temperature_2m: 55, apparent_temperature: 52, weather_code: 45, wind_speed_10m: 10, wind_gusts_10m: 15, is_day: 1), daily: .init(time: [], temperature_2m_max: [], temperature_2m_min: [], sunset: []), minutely_15: .init(time: [start.timeIntervalSince1970, start.timeIntervalSince1970 + 900], precipitation: [0, 1]))
        assert(weather.rainSummary(now: start)?.hasPrefix("rain around") == true)
        assert(weather.rainSummary(now: start.addingTimeInterval(86400)) == nil, "Do not display expired rain timing")
        assert(weather.symbol == "cloud.fog")
        let freeJSON = #"{"bikes":[{"bike_id":"regular","lat":37.7,"lon":-122.4,"is_reserved":0,"is_disabled":0,"type":"classic_bike"},{"bike_id":"electric","lat":37.7,"lon":-122.4,"is_reserved":0,"is_disabled":0,"type":"electric_bike"}]}"#
        let types = try decoder.decode(FreeBikes.self, from: Data(freeJSON.utf8))
        assert(!types.bikes[0].electric && types.bikes[1].electric, "Parked regular bikes must not appear as e-bikes")
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
        print("PASS UTC tide selection, expired forecasts, rain timing, and provider response decoding")
    }
}
