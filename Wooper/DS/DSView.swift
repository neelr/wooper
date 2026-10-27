import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

@available(iOS 27.1, *)
struct DSView: View {
    @Bindable var model: DSModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var importing = false
    @State private var about = false

    var body: some View {
        NavigationStack {
            Group {
                if model.game != nil {
                    ArrangementView {
                        screen(image: model.top, touch: false)
                    } secondary: {
                        screen(image: model.bottom, touch: true)
                    }
                    .arrangementViewStyle(.split)
                    .splitArrangementLayoutRatio(0.5)
                } else {
                    library
                }
            }
            .background(Color.paperyBg)
            .navigationTitle(model.game?.title ?? "DS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.game != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { model.close() } label: { Label("Library", systemImage: "square.grid.2x2") }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button { model.paused ? model.resume() : model.pause() } label: {
                            Label(model.paused ? "Resume" : "Pause", systemImage: model.paused ? "play.fill" : "pause.fill")
                        }.disabled(model.busy)
                        Menu {
                            Button("Save state") { model.state(load: false) }
                            Button("Load state") { model.state(load: true) }
                        } label: { Label("Save states", systemImage: "square.and.arrow.down") }
                        .disabled(model.busy)
                    }
                } else {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { about = true } label: { Label("About DS", systemImage: "info.circle") }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { importing = true } label: { Label("Import ROM", systemImage: "plus") }.disabled(model.busy)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !model.status.isEmpty { Text(model.status).font(.caption).padding(6) }
            }
            .sheet(isPresented: $about) {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Powered by melonDS").font(.title2)
                            Text("Import .nds files from Files. ROMs, in-game saves and save states stay in wooper/DS on this phone. The Mic button generates microphone noise. DS multiplayer, DSi and physical controllers aren't supported yet.")
                            Link("melonDS source and license", destination: URL(string: "https://github.com/libretro/melonds")!)
                            Text(Bundle.main.url(forResource: "MelonDS-License", withExtension: "txt").flatMap { try? String(contentsOf: $0) } ?? "GNU General Public License v3")
                                .font(.caption.monospaced())
                        }.padding()
                    }
                    .toolbar { Button("Done") { about = false } }
                }
            }
            .overlay { if model.busy { ProgressView().padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            .alert("DS", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("OK") { model.error = nil }
            } message: { Text(model.error ?? "") }
            .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "nds") ?? .data], allowsMultipleSelection: true) { result in
                switch result { case .success(let urls): model.importROMs(urls); case .failure(let error): model.error = error.localizedDescription }
            }
            .onAppear { model.refreshLibrary() }
            .onDisappear { model.pause() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { model.pause() } else { model.refreshLibrary() } }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in model.pause() }
        }
    }

    private var library: some View {
        Group {
            if model.games.isEmpty {
                ContentUnavailableView {
                    Label("Your DS library", systemImage: "gamecontroller")
                } description: {
                    Text("Import an uncompressed .nds ROM from Files. Games and saves stay on this phone.")
                } actions: {
                    Button("Import ROM") { importing = true }.buttonStyle(.borderedProminent)
                }
            } else {
                List(model.games) { game in
                    Button { model.play(game) } label: {
                        Label(game.title, systemImage: "gamecontroller").font(.system(.body, design: .monospaced)).padding(.vertical, 8)
                    }
                }
                .refreshable { model.refreshLibrary() }
            }
        }
    }

    private func screen(image: CGImage?, touch: Bool) -> some View {
        VStack(spacing: 8) {
            if touch {
                HStack {
                    pad("L", 10)
                    Spacer()
                    pad("R", 11)
                }
                HStack(spacing: 10) {
                    VStack(spacing: 4) {
                        pad("↑", 4)
                        HStack(spacing: 4) { pad("←", 6); Color.clear.frame(width: 12, height: 44); pad("→", 7) }
                        pad("↓", 5)
                    }
                    display(image: image, touch: true)
                    VStack(spacing: 4) {
                        pad("X", 9)
                        HStack(spacing: 4) { pad("Y", 1); Color.clear.frame(width: 12, height: 44); pad("A", 8) }
                        pad("B", 0)
                    }
                }
                HStack(spacing: 20) {
                    pad("Select", 2)
                    pad("Mic", 12)
                    pad("Start", 3)
                }
            } else {
                display(image: image, touch: false)
            }
        }
        .padding(12)
    }

    private func display(image: CGImage?, touch: Bool) -> some View {
        GeometryReader { geometry in
            let width = max(1, min(geometry.size.width, geometry.size.height * 4 / 3))
            let height = width * 3 / 4
            ZStack {
                Color.black
                if let image { Image(decorative: image, scale: 1).resizable().interpolation(.none) }
                if model.paused { Text("Paused").foregroundStyle(.white).padding(8).background(.black.opacity(0.65), in: Capsule()) }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard touch, !model.paused else { return }
                ds_touch(Int32(value.location.x / width * 256), Int32(value.location.y / height * 192), true)
            }.onEnded { _ in if touch { ds_touch(0, 0, false) } })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func pad(_ title: String, _ id: UInt32) -> some View {
        Text(title)
            .font(.system(.subheadline, design: .monospaced).weight(.semibold))
            .frame(minWidth: 44, minHeight: 44)
            .padding(.horizontal, title.count > 2 ? 5 : 0)
            .background(Color.paperyInk.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !model.paused { ds_button(id, true) } }
                .onEnded { _ in ds_button(id, false) })
            .accessibilityLabel(title).accessibilityAddTraits(.isButton)
            .accessibilityAction { ds_button(id, true); DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { ds_button(id, false) } }
    }
}
