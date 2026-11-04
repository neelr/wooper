import Foundation
import CoreLocation
import Observation

@Observable @MainActor
final class StandbyData: NSObject, @preconcurrency CLLocationManagerDelegate {
    static let sanFrancisco = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
    var location: CLLocation?
    var locationDenied = false
    var weather: StandbyWeather?
    var weatherUpdated: Date?
    var tides: StandbyTides?
    var bikes: [StandbyBike] = []
    var bikesUpdated: Date?
    var bikeError = false
    var weatherError = false
    var tideError = false
    var playback: StandbyPlayback?
    var playbackReceivedAt: Date?
    var papers: [Paper] = []
    var paperError = false
    var loadedPapers = false
    private let manager = CLLocationManager()
    private var running = false
    private var lastConditions: Date = .distantPast
    private var lastCoordinate: CLLocationCoordinate2D?
    private var information: BikeInformation?
    private var informationDate: Date = .distantPast
    var coordinate: CLLocationCoordinate2D { location?.coordinate ?? Self.sanFrancisco }
    var locationKey: String { "\(coordinate.latitude),\(coordinate.longitude)" }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 150
    }
    func startLocation() {
        running = true
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        else { locationManagerDidChangeAuthorization(manager) }
    }
    func stopLocation() { running = false; manager.stopUpdatingLocation() }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        locationDenied = manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted
        if locationDenied { location = nil }
        if running && (manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways) {
            manager.startUpdatingLocation()
        }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let value = locations.last, value.horizontalAccuracy >= 0,
              abs(value.timestamp.timeIntervalSinceNow) < 300 else { return }
        if let location, value.distance(from: location) < 150 { return }
        location = value
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    func refresh(includeBikes: Bool = true) async {
        let coordinate = coordinate
        let moved = lastCoordinate.map {
            CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)) > 1000
        } ?? true
        async let bikeWork: () = refreshBikes(enabled: includeBikes)
        if moved || weatherError || tideError || Date().timeIntervalSince(lastConditions) >= 900 {
            async let weatherWork: () = refreshWeather(coordinate)
            async let tideWork: () = refreshTides()
            _ = await (weatherWork, tideWork)
            if !Task.isCancelled { lastConditions = Date(); lastCoordinate = coordinate }
        }
        await bikeWork
    }
    func refreshPlayback() async {
        do {
            let result: StandbyPlayback = try await Self.fetch("https://neelr.dev/api/spotify")
            guard !Task.isCancelled else { return }
            playback = result
            playbackReceivedAt = Date()
        } catch {
            guard !Task.isCancelled else { return }
            playback = nil
            playbackReceivedAt = nil
        }
    }

    func loadPapers() async {
        do {
            let result = try await PaperyService.list(read: "unread", liked: false, query: "")
            guard !Task.isCancelled else { return }
            papers = result.filter { !$0.isRead }; paperError = false
        } catch { if !Task.isCancelled { paperError = true } }
        loadedPapers = true
    }
    private func refreshWeather(_ coordinate: CLLocationCoordinate2D) async {
        do {
            let url = "https://api.open-meteo.com/v1/forecast?latitude=\(coordinate.latitude)&longitude=\(coordinate.longitude)&current=temperature_2m,apparent_temperature,weather_code,wind_speed_10m,wind_gusts_10m,is_day&daily=temperature_2m_max,temperature_2m_min,sunrise,sunset&minutely_15=precipitation&forecast_minutely_15=24&temperature_unit=fahrenheit&wind_speed_unit=mph&timeformat=unixtime&timezone=auto&forecast_days=2"
            let result: StandbyWeather = try await Self.fetch(url)
            guard !Task.isCancelled else { return }
            weather = result; weatherUpdated = Date(); weatherError = false
        } catch { if !Task.isCancelled { weatherError = true } }
    }
    private func refreshTides() async {
        do {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyyMMdd"
            let start = formatter.string(from: Date())
            let end = formatter.string(from: Date().addingTimeInterval(2 * 86400))
            let result: StandbyTides = try await Self.fetch("https://api.tidesandcurrents.noaa.gov/api/prod/datagetter?product=predictions&application=Flippy&begin_date=\(start)&end_date=\(end)&datum=MLLW&station=9414290&time_zone=gmt&units=english&interval=hilo&format=json")
            guard !Task.isCancelled else { return }
            tides = result; tideError = false
        } catch { if !Task.isCancelled { tideError = true } }
    }
    private func refreshBikes(enabled: Bool) async {
        guard enabled else { return }
        do {
            let base = "https://gbfs.lyft.com/gbfs/1.1/bay/en/"
            if information == nil || Date().timeIntervalSince(informationDate) > 86400 {
                let info: BikeFeed<BikeInformation> = try await Self.fetch(base + "station_information.json")
                information = info.data; informationDate = Date()
            }
            async let status: BikeFeed<BikeStatus> = Self.fetch(base + "station_status.json")
            // Station availability is still useful if the optional free-bike feed fails.
            async let free: BikeFeed<FreeBikes>? = try? Self.fetch(base + "free_bike_status.json")
            let (s, f) = try await (status, free)
            guard !Task.isCancelled else { return }
            let statuses = Dictionary(s.data.stations.map { ($0.station_id, $0) }, uniquingKeysWith: { _, new in new })
            var result = (information?.stations ?? []).compactMap { station -> StandbyBike? in
                guard let state = statuses[station.station_id], state.is_installed == 1, state.is_renting == 1 else { return nil }
                return StandbyBike(id: station.station_id, name: station.name,
                    coordinate: .init(latitude: station.lat, longitude: station.lon), total: state.num_bikes_available,
                    electric: state.num_ebikes_available ?? 0, docks: state.num_docks_available,
                    reported: Date(timeIntervalSince1970: min(s.last_updated, state.last_reported)),
                    rentalURL: station.rental_uris?.ios.flatMap(URL.init(string:)))
            }
            if let f {
                result += f.data.bikes.filter { $0.is_reserved == 0 && $0.is_disabled == 0 }.map { bike in
                    StandbyBike(id: bike.bike_id, name: bike.electric ? "parked e-bike" : "parked bike", coordinate: .init(latitude: bike.lat, longitude: bike.lon),
                        total: 1, electric: bike.electric ? 1 : 0, docks: nil, reported: Date(timeIntervalSince1970: f.last_updated),
                        rentalURL: bike.rental_uris?.ios.flatMap(URL.init(string:)))
                }
            }
            bikes = result; bikesUpdated = Date(timeIntervalSince1970: s.last_updated); bikeError = false
        } catch { if !Task.isCancelled { bikeError = true } }
    }
    private static func fetch<T: Decodable>(_ url: String) async throws -> T {
        guard let url = URL(string: url) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
