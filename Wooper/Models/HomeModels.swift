import Foundation

// Mirrors the JSON from the `home` smart-home API (served on the tailnet at
// http://home.tail90f369.ts.net, backed by Home Assistant on the Raspberry Pi).

struct HomeState: Codable {
    let lights: [Light]
    let sensors: Sensors
    let vacuum: VacuumInfo
}

struct Light: Codable, Identifiable {
    let id: String
    let name: String
    var on: Bool
    var brightness: Int   // 0–100
    var kelvin: Int
    var minK: Int
    var maxK: Int

    enum CodingKeys: String, CodingKey {
        case id, name, on, brightness, kelvin
        case minK = "min_k"
        case maxK = "max_k"
    }
}

struct SensorValue: Codable {
    let state: String?
    let unit: String?
}

struct Sensors: Codable {
    let temp: SensorValue
    let humidity: SensorValue
    let battery: SensorValue
    let download: SensorValue
    let upload: SensorValue
    let sunrise: SensorValue
    let sunset: SensorValue
}

struct VacuumInfo: Codable {
    let state: String?
    let name: String?
}
