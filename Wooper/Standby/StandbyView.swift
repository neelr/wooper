import SwiftUI
import MapKit

struct StandbyView: View {
    let stacked: Bool
    let compactScreen: Bool
    let trigger: StandbyTrigger
    let data: StandbyData
    let dismiss: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @State private var deck = StandbyDeck()
    @State private var paperID: Int?
    @State private var nextPaper = Date().addingTimeInterval(30)
    @State private var now = Date()
    @State private var battery: Float = -1
    @State private var charging = false
    @State private var priorBatteryMonitoring = false
    @State private var priorIdleTimer = false
    @State private var priorBrightness: CGFloat?
    @State private var brightnessScreen: UIScreen?
    @State private var electricOnly = false
    @State private var selectedBikeID: String?
    @State private var camera: MapCameraPosition
    @State private var mapRegion: MKCoordinateRegion?
    @State private var centeredLocation: String?
    private let cream = Color(red: 0.965, green: 0.952, blue: 0.922)
    private let ink = Color(red: 0.17, green: 0.18, blue: 0.16)
    private let muted = Color(red: 0.36, green: 0.37, blue: 0.33)

    init(stacked: Bool, compactScreen: Bool = false, trigger: StandbyTrigger, data: StandbyData, dismiss: @escaping () -> Void) {
        self.stacked = stacked
        self.compactScreen = compactScreen
        self.trigger = trigger
        self.data = data
        self.dismiss = dismiss
        // Viewport-dependent pins must not drive an automatic camera: each
        // changed pin set would reframe the map and select another pin set.
        let region = MKCoordinateRegion(center: data.coordinate, latitudinalMeters: 1600, longitudinalMeters: 1600)
        _camera = State(initialValue: .region(region))
        _mapRegion = State(initialValue: region)
    }

    private var paper: Paper? { data.papers.first { $0.id == paperID } }
    private var mapBikes: [StandbyBike] {
        let region = mapRegion ?? MKCoordinateRegion(center: data.coordinate, latitudinalMeters: 1600, longitudinalMeters: 1600)
        return StandbyBike.inViewport(data.bikes, center: region.center,
            latitudeSpan: region.span.latitudeDelta, longitudeSpan: region.span.longitudeDelta,
            electricOnly: electricOnly)
    }
    private var night: Bool { let hour = Calendar.current.component(.hour, from: now); return hour >= 22 || hour < 6 }
    private var batterySymbol: String {
        charging ? "battery.100percent.bolt" : "battery.\(battery > 0.7 ? 100 : battery > 0.4 ? 50 : battery > 0.15 ? 25 : 0)percent"
    }
    private var rainText: String? {
        guard now.timeIntervalSince(data.weatherUpdated ?? .distantPast) <= 1800 else { return nil }
        return data.weather?.rainSummary(now: now)
    }

    var body: some View {
        GeometryReader { geometry in
            if compactScreen {
                tentLayout(size: geometry.size)
            } else {
                let padding: CGFloat = stacked ? 18 : 20
                let panelHeight = stacked ? (geometry.size.height - 28) / 2 : geometry.size.height
                let panelWidth = stacked ? geometry.size.width : (geometry.size.width - 28) / 2
                let layout = stacked ? AnyLayout(VStackLayout(spacing: 28)) : AnyLayout(HStackLayout(spacing: 28))
                layout {
                    clockPanel(compact: stacked)
                        .padding(padding)
                        .frame(width: panelWidth, height: panelHeight)
                    companionPanel(height: panelHeight - padding * 2, wide: stacked)
                        .padding(.vertical, padding)
                        .padding(.horizontal, stacked ? padding : 0)
                        .frame(width: panelWidth, height: panelHeight)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(cream.ignoresSafeArea())
        .foregroundStyle(ink)
        .font(.system(size: 16, weight: .medium, design: .monospaced))
        .preferredColorScheme(.light)
        .onAppear {
            priorIdleTimer = UIApplication.shared.isIdleTimerDisabled
            priorBatteryMonitoring = UIDevice.current.isBatteryMonitoringEnabled
            UIDevice.current.isBatteryMonitoringEnabled = true
            if paperID == nil && !data.papers.isEmpty { advancePaper() }
            updateBattery(); activate()
        }
        .onDisappear {
            data.stopLocation()
            UIApplication.shared.isIdleTimerDisabled = priorIdleTimer
            UIDevice.current.isBatteryMonitoringEnabled = priorBatteryMonitoring
            restoreBrightness()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { activate(); nextPaper = Date().addingTimeInterval(30) }
            else { data.stopLocation(); UIApplication.shared.isIdleTimerDisabled = priorIdleTimer; restoreBrightness() }
        }
        .task(id: "\(scenePhase)-\(data.locationKey)-\(compactScreen)") {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await data.refresh()
                if !compactScreen { centerMapIfNeeded() }
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await data.loadPapers()
                if paper == nil { advancePaper() }
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await data.refreshPlayback()
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
        .onChange(of: electricOnly) { _, _ in selectedBikeID = nil }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            // A task follows the view's identity. A publisher created in this
            // view's initializer can be replaced on every parent idle tick.
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                let date = Date()
                now = date; updateBattery(); updateBrightness()
                if trigger.policy.touching || date.timeIntervalSince(trigger.policy.lastInteraction) < 2 {
                    nextPaper = date.addingTimeInterval(30)
                } else if date >= nextPaper { advancePaper() }
            }
        }
    }

    private func tentLayout(size: CGSize) -> some View {
        let insets = trigger.contentInsets
        let top = max(14, insets.top)
        let bottom = max(14, insets.bottom)
        let leading = max(20, insets.leading)
        let trailing = max(20, insets.trailing)
        let height = max(1, size.height - top - bottom)
        let width = max(1, size.width - leading - trailing - 24)
        return HStack(spacing: 24) {
            tentClockPanel(height: height)
                .frame(width: width * 0.48, height: height, alignment: .topLeading)
            bookmarkPanel
                .frame(width: width * 0.52, height: height)
        }
        .padding(.top, top).padding(.bottom, bottom)
        .padding(.leading, leading).padding(.trailing, trailing)
    }

    private func tentClockPanel(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(now, format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
                    .font(.system(size: min(112, height * 0.33), weight: .medium, design: .monospaced))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
                    .accessibilityLabel(now.formatted(date: .omitted, time: .shortened))
                Text(now.formatted(.dateTime.weekday(.wide).month(.wide).day()).lowercased())
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .lineLimit(1).minimumScaleFactor(0.8)
                nowPlayingPanel(compact: true).padding(.top, 8)
            }
            Spacer(minLength: 14)
            tentWeatherPanel
            Spacer(minLength: 14)
            tentBikeRow
            Spacer(minLength: 14)
            tentConditions
            Spacer(minLength: 14)
            HStack(spacing: 5) {
                Link("open-meteo", destination: URL(string: "https://open-meteo.com/")!)
                Text("·")
                Link("noaa tides", destination: URL(string: "https://tidesandcurrents.noaa.gov/noaatidepredictions.html?id=9414290")!)
                Spacer(minLength: 2)
                if battery >= 0 {
                    Label("\(Int((battery * 100).rounded()))%", systemImage: batterySymbol)
                        .labelStyle(.titleAndIcon)
                }
            }
            .font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(muted)
        }
    }

    private var tentWeatherPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let weather = data.weather {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: weather.symbol)
                    Text("\(Int(weather.current.temperature_2m.rounded()))°")
                        .font(.system(size: 26, weight: .medium, design: .monospaced))
                    Text(weather.condition).foregroundStyle(muted)
                }.font(.system(size: 13, weight: .medium, design: .monospaced))
                if let rainText {
                    Text(rainText).font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(muted).lineLimit(1).minimumScaleFactor(0.8)
                }
            } else {
                Text(data.weatherError ? "weather unavailable" : "checking the sky…")
                    .font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(muted)
            }
            if data.location == nil {
                Text("san francisco · approximate location")
                    .font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(muted)
            }
        }
    }

    @ViewBuilder private var tentBikeRow: some View {
        if let bike = StandbyBike.nearestAvailable(data.bikes, center: data.coordinate, electricOnly: false).first {
            Button {
                if let url = bike.rentalURL { openURL(url) }
            } label: {
                HStack(alignment: .center, spacing: 9) {
                    Image(systemName: "bicycle").font(.system(size: 18, weight: .medium))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("lyft · \(bikeSummary(bike))")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .lineLimit(1).minimumScaleFactor(0.8)
                        Text(bike.name.lowercased())
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(muted).lineLimit(1)
                        if data.bikeError || now.timeIntervalSince(bike.reported) >= 300 {
                            Text(bikeAge(bike))
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(muted).lineLimit(1)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.up.right").font(.system(size: 10))
                }
                .foregroundStyle(ink).contentShape(Rectangle())
                .padding(.vertical, 5)
            }
            .buttonStyle(.plain).disabled(bike.rentalURL == nil)
            .accessibilityLabel("Lyft, \(bikeSummary(bike)), \(bike.name). Open in Lyft")
        } else {
            Label(data.bikeError ? "lyft bikes unavailable" : data.bikesUpdated == nil ? "finding lyft bikes…" : "no nearby lyft bikes", systemImage: "bicycle")
                .font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(muted)
        }
    }

    private var tentConditions: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let low = data.tides?.nextLow(after: now), let date = low.date {
                let tomorrow = !Calendar.current.isDate(date, inSameDayAs: now)
                Label("low tide \(tomorrow ? "tomorrow " : "")\(date.formatted(date: .omitted, time: .shortened).lowercased())", systemImage: "water.waves")
            }
            HStack(spacing: 12) {
                if let sunrise = data.weather?.daily.sunrise?.first(where: { $0 > now.timeIntervalSince1970 }) {
                    Label(StandbyWeather.time(sunrise), systemImage: "sunrise")
                        .accessibilityLabel("Next sunrise \(StandbyWeather.time(sunrise))")
                }
                if let sunset = data.weather?.daily.sunset.first(where: { $0 > now.timeIntervalSince1970 }) {
                    Label(StandbyWeather.time(sunset), systemImage: "sunset")
                        .accessibilityLabel("Next sunset \(StandbyWeather.time(sunset))")
                }
            }
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundStyle(muted).lineLimit(1).minimumScaleFactor(0.8)
    }

    private func clockPanel(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 14) {
            if compact {
                HStack(alignment: .center, spacing: 24) {
                    clockFace(compact: true).frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 12) {
                        weatherPanel
                        Rectangle().fill(muted.opacity(0.2)).frame(height: 0.5)
                        contextPanel
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                clockFace(compact: false)
                Spacer(minLength: 8)
                weatherPanel
                Spacer(minLength: 8)
                VStack(alignment: .leading, spacing: 16) {
                    Rectangle().fill(muted.opacity(0.2)).frame(height: 0.5)
                    contextPanel
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Link("open-meteo", destination: URL(string: "https://open-meteo.com/")!)
                Text("·")
                Link("noaa tides", destination: URL(string: "https://tidesandcurrents.noaa.gov/noaatidepredictions.html?id=9414290")!)
            }.font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(muted)
            Group {
                if battery >= 0 {
                    Label("\(Int((battery * 100).rounded()))%", systemImage: batterySymbol)
                        .accessibilityLabel("Battery \(Int(battery * 100)) percent\(charging ? ", charging" : "")")
                }
            }
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .foregroundStyle(muted)
            .padding(.leading, 16)
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder private func nowPlayingPanel(compact: Bool = false) -> some View {
        if let playback = data.playback,
           playback.isVisible(now: now, receivedAt: data.playbackReceivedAt) {
            Button {
                if let raw = playback.url, let url = URL(string: raw), url.scheme == "https" { openURL(url) }
            } label: {
                HStack(spacing: 12) {
                    vinylArtwork(playback)
                        .scaleEffect(compact ? 44.0 / 72 : 1)
                        .frame(width: compact ? 44 : 72, height: compact ? 44 : 72)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(playback.song ?? "")
                            .font(.system(size: compact ? 12 : 15, weight: .medium, design: .monospaced))
                            .foregroundStyle(ink).lineLimit(1)
                        if let artist = playback.artist {
                            Text(artist).font(.system(size: compact ? 10 : 12, weight: .medium, design: .monospaced)).lineLimit(1)
                        }
                        if !compact {
                        Text("spotify · \(playback.device?.name ?? "playing")")
                            .font(.system(size: 10, weight: .medium, design: .monospaced)).lineLimit(1)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .foregroundStyle(muted).contentShape(Rectangle())
            }.buttonStyle(.plain)
            .accessibilityLabel("Playing \(playback.song ?? "") by \(playback.artist ?? "") on \(playback.device?.name ?? "Spotify"). Open in Spotify")
        }
    }

    private func vinylArtwork(_ playback: StandbyPlayback) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || scenePhase != .active)) { context in
            let angle = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 12) * 30
            ZStack {
                Circle().fill(Color(white: 0.10).gradient)
                ForEach(0..<5) { groove in
                    Circle().stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                        .frame(width: CGFloat(66 - groove * 5), height: CGFloat(66 - groove * 5))
                }
                AsyncImage(url: playback.albumArt.flatMap(URL.init(string:))) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color(red: 0.65, green: 0.60, blue: 0.49)
                }
                .frame(width: 36, height: 36).clipShape(Circle())
                Circle().fill(cream).frame(width: 5, height: 5)
                    .overlay(Circle().stroke(Color.black.opacity(0.4), lineWidth: 0.5))
            }
            .rotationEffect(.degrees(angle))
            .overlay {
                Circle().fill(AngularGradient(colors: [.clear, .white.opacity(0.09), .clear, .clear, .white.opacity(0.09), .clear], center: .center))
            }
            .frame(width: 72, height: 72)
            .shadow(color: .black.opacity(0.12), radius: 2, y: 2)
        }
        .frame(width: 72, height: 72)
        .accessibilityHidden(true)
    }

    private func clockFace(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(now, format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
                .font(.system(size: compact ? 112 : 154, weight: .medium, design: .monospaced))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.45)
                .accessibilityLabel(now.formatted(date: .omitted, time: .shortened))
            Text(now.formatted(.dateTime.weekday(.wide).month(.wide).day()).lowercased())
                .font(.system(size: compact ? 19 : 23, weight: .medium, design: .monospaced))
                .lineLimit(2)
            nowPlayingPanel().padding(.top, 14)
        }
    }

    private var weatherPanel: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let weather = data.weather {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: weather.symbol)
                    Text("\(Int(weather.current.temperature_2m.rounded()))°")
                        .font(.system(size: 44, weight: .medium, design: .monospaced))
                    Text(weather.condition).foregroundStyle(muted)
                }
                Text("feels \(Int(weather.current.apparent_temperature.rounded()))°  ↑\(Int(weather.daily.temperature_2m_max.first ?? 0))° ↓\(Int(weather.daily.temperature_2m_min.first ?? 0))°")
                    .foregroundStyle(muted)
                if weather.current.wind_speed_10m >= 8 {
                    Text("wind \(Int(weather.current.wind_speed_10m.rounded())) · gusts \(Int(weather.current.wind_gusts_10m.rounded())) mph").foregroundStyle(muted)
                }
                if let rainText { Text(rainText).foregroundStyle(muted) }
                if data.weatherError || now.timeIntervalSince(data.weatherUpdated ?? .distantPast) > 1800 {
                    Text("weather may be out of date").foregroundStyle(muted)
                }
            } else {
                Label(data.weatherError ? "weather unavailable" : "checking the sky…", systemImage: "cloud").foregroundStyle(muted)
            }
            if data.location == nil { Text("san francisco · approximate location").font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(muted) }
        }
    }

    private var contextPanel: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let low = data.tides?.nextLow(after: now), let date = low.date {
                let tomorrow = !Calendar.current.isDate(date, inSameDayAs: now)
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "water.waves")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("low tide \(tomorrow ? "tomorrow " : "")\(date.formatted(date: .omitted, time: .shortened).lowercased())")
                        Text("golden gate · \(String(format: "%.1f", Double(low.v) ?? 0)) ft\(data.tideError ? " · cached" : "")")
                            .font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(muted)
                    }
                }
            } else {
                Label(data.tideError ? "tides unavailable" : "checking the tide…", systemImage: "water.waves").foregroundStyle(muted)
            }
            if let sunrise = data.weather?.daily.sunrise?.first(where: { $0 > now.timeIntervalSince1970 }) {
                let date = Date(timeIntervalSince1970: sunrise)
                let tomorrow = !Calendar.current.isDate(date, inSameDayAs: now)
                Label("sunrise \(tomorrow ? "tomorrow " : "")\(StandbyWeather.time(sunrise))", systemImage: "sunrise")
                    .foregroundStyle(muted)
            }
            if let sunset = data.weather?.daily.sunset.first(where: { $0 > now.timeIntervalSince1970 }) {
                let date = Date(timeIntervalSince1970: sunset)
                let tomorrow = !Calendar.current.isDate(date, inSameDayAs: now)
                let minutes = Int(date.timeIntervalSince(now) / 60)
                Label("sunset \(tomorrow ? "tomorrow " : "")\(StandbyWeather.time(sunset))\(minutes < 120 ? " · \(minutes)m left" : "")", systemImage: "sunset").foregroundStyle(muted)
            }
        }
        .font(.system(size: 13, weight: .medium, design: .monospaced))
    }

    private func companionPanel(height: CGFloat, wide: Bool) -> some View {
        let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 24)) : AnyLayout(VStackLayout(spacing: 22))
        return layout {
            bikePanel(mapHeight: max(95, wide ? height - 125 : height * 0.34))
                .padding(.horizontal, wide ? 0 : 20)
                .frame(maxWidth: .infinity, maxHeight: wide ? .infinity : nil, alignment: .top)
            bookmarkPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func bikePanel(mapHeight: CGFloat) -> some View {
        // Compute one snapshot for this render. Annotation closures used to
        // filter and sort the entire feed twice for every individual marker.
        let visibleBikes = mapBikes
        let selected = visibleBikes.first { $0.id == selectedBikeID } ??
            visibleBikes.first { (electricOnly ? $0.electric : $0.total) > 0 } ?? visibleBikes.first
        let highlightedID = selected?.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(data.location == nil ? "bay wheels / sf" : "bay wheels / nearby").tracking(0.3)
                Spacer(minLength: 2)
                Button {
                    selectedBikeID = nil; centeredLocation = nil; centerMapIfNeeded()
                } label: {
                    Image(systemName: "location").frame(width: 24, height: 24)
                }.accessibilityLabel("Show bikes near me")
                Button { electricOnly.toggle() } label: {
                    HStack(spacing: 3) {
                        if electricOnly { Image(systemName: "bolt.fill") }
                        Text(electricOnly ? "e-bikes" : "all bikes").underline()
                    }
                }.accessibilityLabel(electricOnly ? "Showing e-bikes. Show all bikes" : "Showing all bikes. Show e-bikes")
            }.font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(muted)
            Map(position: $camera, interactionModes: [.pan, .zoom]) {
                if let location = data.location {
                    Annotation("you", coordinate: location.coordinate) {
                        Circle().fill(Color(red: 0.43, green: 0.5, blue: 0.4)).frame(width: 10, height: 10)
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                    }
                }
                ForEach(visibleBikes) { bike in
                    Annotation(bike.name, coordinate: bike.coordinate) {
                        Button {
                            selectedBikeID = bike.id
                        } label: {
                            HStack(spacing: 2) {
                                if electricOnly { Image(systemName: "bolt.fill").font(.system(size: 8)) }
                                Text("\(electricOnly ? bike.electric : bike.total)").font(.system(size: 12, weight: .medium, design: .monospaced))
                            }
                            .padding(7)
                            .background(highlightedID == bike.id ? ink : cream, in: Capsule())
                            .foregroundStyle(highlightedID == bike.id ? cream : ink)
                            .overlay(Capsule().stroke(ink.opacity(0.25), lineWidth: 0.5))
                            .opacity(now.timeIntervalSince(bike.reported) > 300 ? 0.5 : (electricOnly ? bike.electric : bike.total) == 0 ? 0.65 : 1)
                        }
                        .accessibilityLabel("\(bike.name), \(electricOnly ? bike.electric : bike.total) bikes")
                    }.annotationTitles(.hidden)
                }
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                mapRegion = context.region
            }
            .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
            .frame(height: mapHeight).clipShape(RoundedRectangle(cornerRadius: 8))
            if let bike = selected {
                Button {
                    if let url = bike.rentalURL { openURL(url) }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(bikeSummary(bike))
                                .lineLimit(1).minimumScaleFactor(0.7)
                            Spacer(minLength: 3)
                            Image(systemName: "arrow.up.right")
                        }
                        Text(bike.name.lowercased()).lineLimit(1).minimumScaleFactor(0.8).foregroundStyle(muted)
                    }.font(.system(size: 13, weight: .medium, design: .monospaced))
                }.buttonStyle(.plain).disabled(bike.rentalURL == nil)
                HStack(spacing: 5) {
                    Text("\(bike.electric) electric ·")
                    if let docks = bike.docks { Text("\(docks) docks ·") }
                    Text(bikeAge(bike))
                }.font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(muted)
            } else {
                Text(data.bikeError ? "bike availability unavailable" : data.bikesUpdated == nil ? "finding bikes…" : "no bikes or stations in this area")
                    .font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(muted)
            }
        }
    }

    private var bookmarkPanel: some View {
        VStack(alignment: .leading, spacing: compactScreen ? 8 : 12) {
            if let paper {
                Button {
                    if let url = URL(string: paper.url) { dismiss(); openURL(url) }
                } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        GeometryReader { geometry in
                            PaperThumb(url: paper.url, width: max(1, geometry.size.width),
                                       height: max(1, geometry.size.height), alignment: .top)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(paper.displayTitle)")
                .id(paper.id).transition(.opacity)
                HStack(alignment: .center, spacing: 12) {
                    Button {
                        if let url = URL(string: paper.url) { dismiss(); openURL(url) }
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(paper.displayTitle)
                                .font(.system(size: compactScreen ? 14 : 18, weight: .medium, design: .monospaced))
                                .foregroundStyle(ink).lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Text((URL(string: paper.url)?.host ?? paper.site ?? "saved link").replacingOccurrences(of: "www.", with: ""))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                    Button { advancePaper() } label: {
                        Image(systemName: "arrow.right").frame(width: 32, height: 24)
                    }.accessibilityLabel("Next bookmark")
                }
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(muted)
                .padding(.horizontal, stacked || compactScreen ? 0 : 20)
                GeometryReader { geometry in
                    Rectangle().fill(muted.opacity(0.2)).frame(width: geometry.size.width * max(0, min(1, 1 - nextPaper.timeIntervalSince(now) / 30)), height: 1)
                }.frame(height: 1).accessibilityHidden(true)
            } else {
                Text(data.paperError ? "bookmarks unavailable right now" : data.loadedPapers ? "your unread pile is clear" : "opening your unread pile…")
                    .foregroundStyle(muted)
            }
        }
    }

    private func bikeSummary(_ bike: StandbyBike) -> String {
        let count = electricOnly ? bike.electric : bike.total
        if count == 0 { return electricOnly && bike.total > 0 ? "no e-bikes · \(bike.total) regular bikes" : "no bikes available here" }
        let noun = electricOnly ? (count == 1 ? "e-bike" : "e-bikes") : (count == 1 ? "bike" : "bikes")
        let walk = data.location == nil ? "" : "~\(max(1, Int(ceil(bike.distance(from: data.coordinate) * 1.3 / 80)))) min walk · "
        return "\(walk)\(count) \(noun)"
    }

    private func bikeAge(_ bike: StandbyBike) -> String {
        let age = max(0, Int(now.timeIntervalSince(bike.reported) / 60))
        if data.bikeError || age >= 5 { return "last seen \(age)m ago · may be stale" }
        return age == 0 ? "updated just now" : "updated \(age)m ago"
    }
    private func advancePaper() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.5)) {
            paperID = deck.next(ids: data.papers.map(\.id))
        }
        nextPaper = Date().addingTimeInterval(30)
    }
    private func centerMapIfNeeded() {
        guard centeredLocation != data.locationKey else { return }
        let coordinate = data.coordinate
        let nearby = StandbyBike.nearestAvailable(data.bikes, center: coordinate, electricOnly: electricOnly)
        if !nearby.isEmpty { centeredLocation = data.locationKey }
        let radius = max(400, (nearby.last?.distance(from: coordinate) ?? 700) * 1.3)
        let region = MKCoordinateRegion(center: coordinate, latitudinalMeters: radius * 2, longitudinalMeters: radius * 2)
        mapRegion = region
        camera = .region(region)
    }
    private func updateBattery() {
        battery = UIDevice.current.batteryLevel
        charging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
    }
    private func activate() {
        guard scenePhase == .active else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        data.startLocation(); updateBrightness()
    }
    private func updateBrightness() {
        guard let screen = trigger.screen else { return }
        if brightnessScreen !== screen { restoreBrightness() }
        if night {
            if priorBrightness == nil { priorBrightness = screen.brightness; brightnessScreen = screen }
            screen.brightness = min(priorBrightness ?? 0.15, 0.15)
        } else { restoreBrightness() }
    }
    private func restoreBrightness() {
        if let priorBrightness { brightnessScreen?.brightness = priorBrightness }
        priorBrightness = nil
        brightnessScreen = nil
    }
}
