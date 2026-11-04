import Foundation
import CoreLocation

struct StandbyWeather: Decodable {
    struct Current: Decodable {
        let temperature_2m: Double
        let apparent_temperature: Double
        let weather_code: Int
        let wind_speed_10m: Double
        let wind_gusts_10m: Double
        let is_day: Int
    }
    struct Daily: Decodable {
        let time: [Double]
        let temperature_2m_max: [Double]
        let temperature_2m_min: [Double]
        let sunset: [Double]
        var sunrise: [Double]? = nil
    }
    struct QuarterHours: Decodable {
        let time: [Double]
        let precipitation: [Double?]
    }
    let current: Current
    let daily: Daily
    let minutely_15: QuarterHours?

    var symbol: String {
        switch current.weather_code {
        case 0: return current.is_day == 1 ? "sun.max" : "moon"
        case 1, 2: return current.is_day == 1 ? "cloud.sun" : "cloud.moon"
        case 3: return "cloud"
        case 45, 48: return "cloud.fog"
        case 71...77, 85, 86: return "cloud.snow"
        case 95...99: return "cloud.bolt.rain"
        default: return "cloud.rain"
        }
    }
    var condition: String {
        switch current.weather_code {
        case 0: return "clear"
        case 1, 2: return "partly cloudy"
        case 3: return "cloudy"
        case 45, 48: return "foggy"
        case 71...77, 85, 86: return "snow"
        case 95...99: return "thunderstorms"
        default: return "rain"
        }
    }
    func rainSummary(now: Date) -> String? {
        guard let forecast = minutely_15 else { return nil }
        let next = zip(forecast.time, forecast.precipitation).filter {
            $0.0 >= now.timeIntervalSince1970 - 900 && $0.0 < now.timeIntervalSince1970 + 6 * 3600
        }
        guard let first = next.first else { return nil }
        if let amount = first.1, amount >= 0.1 {
            if let end = next.dropFirst().first(where: { ($0.1 ?? 1) < 0.1 }) {
                return "rain easing around \(Self.time(end.0))"
            }
            return "rain for the next few hours"
        }
        if let rain = next.first(where: { ($0.1 ?? 0) >= 0.1 }) {
            return "rain around \(Self.time(rain.0))"
        }
        return nil
    }
    static func time(_ epoch: Double) -> String {
        Date(timeIntervalSince1970: epoch).formatted(date: .omitted, time: .shortened).lowercased()
    }
}

struct StandbyTides: Decodable {
    struct Prediction: Decodable {
        let t: String
        let v: String
        let type: String
        var date: Date? {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            return formatter.date(from: t)
        }
    }
    let predictions: [Prediction]
    func nextLow(after now: Date) -> Prediction? {
        predictions.first { $0.type == "L" && ($0.date ?? .distantPast) >= now }
    }
}

struct BikeFeed<Value: Decodable>: Decodable {
    let last_updated: Double
    let data: Value
}
struct BikeInformation: Decodable {
    struct Station: Decodable {
        let station_id: String
        let name: String
        let lat: Double
        let lon: Double
        let rental_uris: RentalURIs?
    }
    let stations: [Station]
}
struct RentalURIs: Decodable { let ios: String? }
struct BikeStatus: Decodable {
    struct Station: Decodable {
        let station_id: String
        let num_bikes_available: Int
        let num_ebikes_available: Int?
        let num_docks_available: Int
        let is_installed: Int
        let is_renting: Int
        let last_reported: Double
    }
    let stations: [Station]
}
struct FreeBikes: Decodable {
    struct Bike: Decodable {
        let bike_id: String
        let lat: Double
        let lon: Double
        let is_reserved: Int
        let is_disabled: Int
        let type: String?
        let rental_uris: RentalURIs?
        var electric: Bool { type == "electric_bike" }
    }
    let bikes: [Bike]
}
struct StandbyBike: Identifiable {
    let id: String
    let name: String
    let coordinate: CLLocationCoordinate2D
    let total: Int
    let electric: Int
    let docks: Int?
    let reported: Date
    let rentalURL: URL?
    var isStation: Bool { docks != nil }
    func distance(from coordinate: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: self.coordinate.latitude, longitude: self.coordinate.longitude)
            .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
    }
}


extension StandbyBike {
    /// Markers follow the visible map, not the user's six nearest available bikes.
    /// Empty stations remain visible; a zero is useful information, not missing data.
    static func inViewport(_ bikes: [StandbyBike], center: CLLocationCoordinate2D,
                           latitudeSpan: Double, longitudeSpan: Double,
                           electricOnly: Bool) -> [StandbyBike] {
        let candidates = bikes.filter { bike in
            guard bike.isStation || (electricOnly ? bike.electric : bike.total) > 0 else { return false }
            let longitudeDistance = abs(bike.coordinate.longitude - center.longitude).truncatingRemainder(dividingBy: 360)
            return abs(bike.coordinate.latitude - center.latitude) <= latitudeSpan / 2 &&
                min(longitudeDistance, 360 - longitudeDistance) <= longitudeSpan / 2
        }
        return ranked(candidates, center: center).prefix(120).map(\.bike)
    }

    static func nearestAvailable(_ bikes: [StandbyBike], center: CLLocationCoordinate2D,
                                 electricOnly: Bool) -> [StandbyBike] {
        let candidates = bikes.filter { (electricOnly ? $0.electric : $0.total) > 0 }
        return ranked(candidates, center: center).prefix { $0.distance < 5000 }.prefix(6).map(\.bike)
    }

    private static func ranked(_ bikes: [StandbyBike], center: CLLocationCoordinate2D) -> [(bike: StandbyBike, distance: Double)] {
        let origin = CLLocation(latitude: center.latitude, longitude: center.longitude)
        // Core Location distance evaluation allocates objects. Do it once per
        // candidate, not repeatedly inside the sorting comparator.
        return bikes.map { bike in
            let location = CLLocation(latitude: bike.coordinate.latitude, longitude: bike.coordinate.longitude)
            return (bike: bike, distance: location.distance(from: origin))
        }.sorted { $0.distance < $1.distance }
    }
}
