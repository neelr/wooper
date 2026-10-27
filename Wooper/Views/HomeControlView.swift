import SwiftUI

/// "home" tab — control the lamps + Matic vacuum and glance at house sensors,
/// all over the tailnet. Matches the papery theme used by the other tabs.
///
/// Responsiveness: every control updates local state instantly (optimistic) and
/// fires the network request in the background — the UI never waits on a round
/// trip. The 5s poll reconciles with the server, but is suppressed while the
/// user is interacting and for a short hold window after each action so it can't
/// snap a control back before the change has propagated through Matter.
struct HomeControlView: View {
    @State private var lights: [Light] = []
    @State private var sensors: Sensors?
    @State private var vacuumState: String = "—"
    @State private var errorText: String?
    @State private var loaded = false

    @State private var interacting = false
    @State private var holdUntil = Date.distantPast

    private let ticker = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    private let amber = Color(red: 0.88, green: 0.65, blue: 0.0)

    var body: some View {
        NavigationStack {
            ZStack {
                Color.paperyBg.ignoresSafeArea()

                if !loaded {
                    ProgressView().tint(Color.paperyMeta)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            lightsSection
                            vacuumSection
                            sensorsSection
                            if let errorText {
                                Text(errorText)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.red)
                            }
                        }
                        .padding(18)
                    }
                }
            }
            .navigationTitle("home")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbarBackground(Color.paperyBg, for: .navigationBar)
        }
        .preferredColorScheme(.light)
        .tint(Color.paperyInk)
        .task { await load() }
        .onReceive(ticker) { _ in Task { await load(silent: true) } }
    }

    // MARK: sections

    private var lightsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("lights")
            HStack(spacing: 8) {
                pill("all on") { setAll(on: true) }
                pill("all off") { setAll(on: false) }
            }
            ForEach($lights) { $light in
                LightCard(light: $light, amber: amber,
                    onSetOn: { on in hold(); fireAndForget { try await HomeService.setLight(light.id, on: on) } },
                    onBrightness: { v in hold(); fireAndForget { try await HomeService.setLight(light.id, brightness: v) } },
                    onKelvin: { v in hold(); fireAndForget { try await HomeService.setLight(light.id, kelvin: v) } },
                    onInteracting: { interacting = $0 })
            }
        }
    }

    private var vacuumSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("vacuum")
            HStack(spacing: 10) {
                Circle()
                    .fill(vacuumState == "docked" || vacuumState == "—" ? Color.paperyMeta.opacity(0.4) : amber)
                    .frame(width: 8, height: 8)
                Text(vacuumState)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(Color.paperyInk)
                Spacer()
                pill("start") { vacuum("start", optimistic: "cleaning") }
                pill("pause") { vacuum("pause", optimistic: "paused") }
                pill("dock") { vacuum("dock", optimistic: "returning") }
            }
            .padding(14)
            .background(cardBackground)
        }
    }

    private var sensorsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("home")
            if let s = sensors {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    stat("temperature", value(s.temp.state), unit: "°F")
                    stat("humidity", value(s.humidity.state), unit: "%")
                    stat("sunrise", timeOf(s.sunrise.state), unit: "")
                    stat("sunset", timeOf(s.sunset.state), unit: "")
                    stat("internet", "\(intVal(s.download.state))↓ \(intVal(s.upload.state))↑", unit: "KiB/s")
                    stat("sensor batt", value(s.battery.state), unit: "%")
                }
            }
        }
    }

    // MARK: actions (optimistic)

    private func setAll(on: Bool) {
        hold()
        for i in lights.indices { lights[i].on = on }
        fireAndForget { try await HomeService.allLights(on: on) }
    }

    private func vacuum(_ action: String, optimistic: String) {
        hold()
        vacuumState = optimistic
        fireAndForget { try await HomeService.vacuum(action) }
    }

    /// Suppress the reconciling poll from overwriting controls for a short window
    /// after an action, so it can't flip a control back before Matter reports in.
    private func hold() { holdUntil = Date().addingTimeInterval(2.5) }

    private func fireAndForget(_ op: @escaping () async throws -> Void) {
        Task { do { try await op() } catch { errorText = error.localizedDescription } }
    }

    // MARK: building blocks

    private func sectionHeader(_ t: String) -> some View {
        Text(t)
            .font(.system(.caption2, design: .monospaced))
            .tracking(1)
            .foregroundStyle(Color.paperyMeta)
    }

    private func pill(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.paperyInk)
                .padding(.vertical, 6).padding(.horizontal, 12)
                .background(cardBackground)
        }
        .buttonStyle(.plain)
    }

    private func stat(_ key: String, _ val: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(key)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Color.paperyMeta)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(val)
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .foregroundStyle(Color.paperyInk)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Color.paperyMeta)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(cardBackground)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.paperyMeta.opacity(0.06))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.paperyMeta.opacity(0.18), lineWidth: 1))
    }

    // MARK: data

    private func load(silent: Bool = false) async {
        do {
            let s = try await HomeService.fetchState()
            sensors = s.sensors                                   // sensors always refresh
            let applyControls = !interacting && Date() >= holdUntil
            if applyControls {
                lights = s.lights
                vacuumState = s.vacuum.state ?? "—"
            }
            errorText = nil
            loaded = true
        } catch {
            if !silent { errorText = error.localizedDescription }
            loaded = true
        }
    }

    private func value(_ s: String?) -> String { s ?? "—" }
    private func intVal(_ s: String?) -> String { String(Int(Double(s ?? "0") ?? 0)) }
    private func timeOf(_ iso: String?) -> String {
        guard let iso, let d = ISO8601DateFormatter().date(from: iso) else { return "—" }
        let f = DateFormatter(); f.dateFormat = "h:mm a"
        return f.string(from: d)
    }
}

private struct LightCard: View {
    @Binding var light: Light
    let amber: Color
    var onSetOn: (Bool) -> Void
    var onBrightness: (Int) -> Void
    var onKelvin: (Int) -> Void
    var onInteracting: (Bool) -> Void

    @State private var lastBri = Date.distantPast
    @State private var lastKelvin = Date.distantPast

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle()
                    .fill(light.on ? amber : Color.paperyMeta.opacity(0.35))
                    .frame(width: 9, height: 9)
                Text(light.name)
                    .font(.system(.body, design: .monospaced).weight(.medium))
                    .foregroundStyle(Color.paperyInk)
                Spacer()
                Button {
                    light.on.toggle()          // optimistic: writes through the binding
                    onSetOn(light.on)
                } label: {
                    Text(light.on ? "on" : "off")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(light.on ? Color.paperyBg : Color.paperyInk)
                        .padding(.vertical, 5).padding(.horizontal, 14)
                        .background(
                            Capsule().fill(light.on ? Color.paperyInk : Color.clear)
                                .overlay(Capsule().stroke(Color.paperyMeta.opacity(0.4), lineWidth: light.on ? 0 : 1))
                        )
                }
                .buttonStyle(.plain)
            }

            sliderLabel("brightness", "\(light.brightness)%")
            Slider(value: Binding(
                        get: { Double(light.brightness) },
                        set: { v in
                            light.brightness = Int(v)          // live local update
                            throttle(&lastBri) { onBrightness(light.brightness) }
                        }),
                   in: 1...100,
                   onEditingChanged: { editing in
                        onInteracting(editing)
                        if !editing { onBrightness(light.brightness) }   // ensure final value lands
                   })
                .tint(Color.paperyInk)

            sliderLabel("warmth", "\(light.kelvin)K")
            Slider(value: Binding(
                        get: { Double(light.kelvin) },
                        set: { v in
                            light.kelvin = Int(v)
                            throttle(&lastKelvin) { onKelvin(light.kelvin) }
                        }),
                   in: Double(light.minK)...Double(light.maxK), step: 50,
                   onEditingChanged: { editing in
                        onInteracting(editing)
                        if !editing { onKelvin(light.kelvin) }
                   })
                .tint(amber)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.paperyMeta.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.paperyMeta.opacity(0.18), lineWidth: 1))
        )
    }

    /// Fire `send` at most every ~150ms so the lamp tracks the drag live without
    /// flooding Home Assistant.
    private func throttle(_ last: inout Date, _ send: () -> Void) {
        let now = Date()
        if now.timeIntervalSince(last) > 0.15 {
            last = now
            send()
        }
    }

    private func sliderLabel(_ l: String, _ v: String) -> some View {
        HStack {
            Text(l).font(.system(.caption2, design: .monospaced)).foregroundStyle(Color.paperyMeta)
            Spacer()
            Text(v).font(.system(.caption2, design: .monospaced)).foregroundStyle(Color.paperyMeta)
        }
    }
}

#Preview {
    HomeControlView()
}
