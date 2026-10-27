import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

@available(iOS 27.1, *)
struct DSView: View {
    @Bindable var model: DSModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var importing = false
    @State private var about = false
    private let shell = Color(red: 0.62, green: 0.83, blue: 0.90)
    private let controlInk = Color(red: 0.19, green: 0.39, blue: 0.46)

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
            .background(model.game == nil ? Color.paperyBg : shell)
            .navigationTitle(model.game?.title ?? "DS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.game == nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { about = true } label: { Label("About DS", systemImage: "info.circle") }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { importing = true } label: { Label("Import ROM", systemImage: "plus") }.disabled(model.busy)
                    }
                }
            }
            .toolbar(model.game == nil ? .visible : .hidden, for: .navigationBar, .tabBar)
            .statusBarHidden(model.game != nil)
            .persistentSystemOverlays(model.game == nil ? .automatic : .hidden)
            .sheet(isPresented: $about) {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Powered by melonDS").font(.title2)
                            Text("Import .nds files from Files. ROMs, in-game saves and save states stay in wooper/DS on this phone. DS multiplayer, DSi and physical controllers aren't supported yet.")
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

    private var gameMenu: some View {
        Menu {
            Button(model.paused ? "Resume" : "Pause") { model.paused ? model.resume() : model.pause() }
            Button("Save state") { model.state(load: false) }
            Button("Load state") { model.state(load: true) }
            if !model.status.isEmpty { Text(model.status) }
            Button("Back to library") { model.close() }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 18, weight: .bold))
                .foregroundStyle(controlInk.opacity(0.7)).frame(width: 44, height: 44)
        }.disabled(model.busy)
    }

    private var speaker: some View {
        VStack(spacing: 5) {
            ForEach(0..<6) { _ in
                Capsule().fill(controlInk.opacity(0.6)).frame(width: 18, height: 3)
            }
        }.accessibilityHidden(true)
    }

    private func screen(image: CGImage?, touch: Bool) -> some View {
        VStack(spacing: 4) {
            if touch {
                HStack {
                    pad("L", 10)
                    Spacer()
                    Capsule().fill(controlInk.opacity(0.25)).frame(width: 80, height: 5)
                    Spacer()
                    pad("R", 11)
                }
                HStack(spacing: 8) {
                    controlDiamond(top: ("↑", 4), left: ("←", 6), right: ("→", 7), bottom: ("↓", 5))
                    display(image: image, touch: true)
                    controlDiamond(top: ("X", 9), left: ("Y", 1), right: ("A", 8), bottom: ("B", 0))
                }
                HStack(spacing: 12) {
                    gameMenu
                    Spacer()
                    pad("SELECT", 2)
                    pad("START", 3)
                }
            } else {
                HStack(spacing: 12) {
                    speaker
                    display(image: image, touch: false)
                    speaker
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, touch ? 4 : 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LinearGradient(colors: [Color(red: 0.77, green: 0.91, blue: 0.95), shell, Color(red: 0.52, green: 0.75, blue: 0.84)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .overlay(alignment: touch ? .top : .bottom) {
            Rectangle().fill(controlInk.opacity(0.35)).frame(height: 3).accessibilityHidden(true)
        }
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
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black, lineWidth: 5))
            .shadow(color: .black.opacity(0.6), radius: 2, y: 2)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard touch, !model.paused else { return }
                ds_touch(Int32(value.location.x / width * 256), Int32(value.location.y / height * 192), true)
            }.onEnded { _ in if touch { ds_touch(0, 0, false) } })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func controlDiamond(top: (String, UInt32), left: (String, UInt32), right: (String, UInt32), bottom: (String, UInt32)) -> some View {
        ZStack {
            if top.0 == "↑" {
                RoundedRectangle(cornerRadius: 3).fill(shell).frame(width: 44, height: 44)
            }
            pad(top.0, top.1).offset(y: -44)
            pad(left.0, left.1).offset(x: -44)
            pad(right.0, right.1).offset(x: 44)
            pad(bottom.0, bottom.1).offset(y: 44)
        }
        .frame(width: 132, height: 132)
    }

    private func pad(_ title: String, _ id: UInt32) -> some View {
        Text(title)
            .font(.system(size: title.count > 2 ? 9 : 16, weight: .bold, design: .monospaced))
            .foregroundStyle(controlInk)
            .frame(width: 44, height: 44)
            .background {
                RoundedRectangle(cornerRadius: title.count == 1 && "ABXY".contains(title) ? 22 : 6)
                    .fill(LinearGradient(colors: [Color(red: 0.85, green: 0.95, blue: 0.98), Color(red: 0.62, green: 0.82, blue: 0.89)], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: title.count == 1 && "ABXY".contains(title) ? 22 : 6).stroke(controlInk.opacity(0.35), lineWidth: 1))
                    .shadow(color: controlInk.opacity(0.4), radius: 1, y: 2)
                    .padding(3)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !model.paused { ds_button(id, true) } }
                .onEnded { _ in ds_button(id, false) })
            .accessibilityLabel(title).accessibilityAddTraits(.isButton)
            .accessibilityAction { ds_button(id, true); DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { ds_button(id, false) } }
    }
}
