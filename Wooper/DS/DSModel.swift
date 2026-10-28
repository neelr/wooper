import SwiftUI
import AVFoundation

struct DSGame: Identifiable, Hashable {
    let url: URL
    let title: String
    var id: String { url.lastPathComponent }
}

final class DSWorker: @unchecked Sendable {
    let queue = DispatchQueue(label: "wooper.ds.core", qos: .userInteractive)
    var timer: DispatchSourceTimer?
    var current: URL?
    var frame: ((CGImage) -> Void)?
    var framePending = false
    let frameLock = NSLock()

    func startTimer() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 59.8261, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            ds_run()
            self.frameLock.lock()
            let pending = self.framePending
            self.framePending = true
            self.frameLock.unlock()
            guard !pending else { return }
            let data = Data(bytes: ds_pixels()!, count: 256 * 384 * 4)
            guard let provider = CGDataProvider(data: data as CFData),
                  let image = CGImage(width: 256, height: 384, bitsPerComponent: 8, bitsPerPixel: 32,
                                      bytesPerRow: 1024, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue).union(.byteOrder32Little),
                                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
            else { self.frameLock.lock(); self.framePending = false; self.frameLock.unlock(); return }
            DispatchQueue.main.async {
                self.frame?(image)
                self.frameLock.lock(); self.framePending = false; self.frameLock.unlock()
            }
        }
        self.timer = timer
        timer.resume()
    }

    func pause() { timer?.cancel(); timer = nil; ds_clear_input() }
}

@MainActor @Observable
final class DSModel {
    var games: [DSGame] = []
    var game: DSGame?
    var top: CGImage?
    var bottom: CGImage?
    var paused = true
    var busy = false
    var error: String?
    var status = ""
    private let worker = DSWorker()
    private var audio: AVAudioEngine?
    private var resumeAfterLoad = false
    private var lastOpened = UserDefaults.standard.dictionary(forKey: "ds.lastOpened") as? [String: Double] ?? [:]
    static let root = URL.documentsDirectory.appending(path: "DS")
    static var roms: URL { root.appending(path: "ROMs") }
    static var saves: URL { root.appending(path: "Saves") }
    static var system: URL { root.appending(path: "System") }

    init() {
        worker.frame = { [weak self] image in
            self?.top = image.cropping(to: CGRect(x: 0, y: 0, width: 256, height: 192))
            self?.bottom = image.cropping(to: CGRect(x: 0, y: 192, width: 256, height: 192))
        }
        refreshLibrary()
    }

    func refreshLibrary() {
        do {
            for dir in [Self.roms, Self.saves, Self.system] {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            try applyLibraryEdits()
            let titlesURL = Self.root.appending(path: "library-titles.json")
            let titles = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: titlesURL))) ?? [:]
            games = try FileManager.default.contentsOfDirectory(at: Self.roms, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "nds" }
                .map { DSGame(url: $0, title: (titles[$0.lastPathComponent] ?? $0.deletingPathExtension().lastPathComponent).lowercased()) }
            sortLibrary()
        } catch { self.error = error.localizedDescription }
    }

    private func sortLibrary() {
        games.sort {
            let left = lastOpened[$0.id] ?? 0
            let right = lastOpened[$1.id] ?? 0
            if left != right { return left > right }
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    private func recordOpened(_ game: DSGame) {
        lastOpened[game.id] = Date().timeIntervalSince1970
        UserDefaults.standard.set(lastOpened, forKey: "ds.lastOpened")
        sortLibrary()
    }

    /// Local maintenance requests let the desktop manage the library without changing save identities.
    private func applyLibraryEdits() throws {
        struct Edits: Decodable {
            let titles: [String: String]
            let remove: [String]
        }
        let request = Self.root.appending(path: "library-edits.json")
        guard FileManager.default.fileExists(atPath: request.path) else { return }
        let edits = try JSONDecoder().decode(Edits.self, from: Data(contentsOf: request))
        for name in Array(edits.titles.keys) + edits.remove {
            guard !name.contains("/"), !name.contains("\\"), name.lowercased().hasSuffix(".nds") else {
                throw DSError.message("Invalid library filename.")
            }
        }
        let titlesURL = Self.root.appending(path: "library-titles.json")
        var titles = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: titlesURL))) ?? [:]
        titles.merge(edits.titles) { _, new in new }
        try JSONEncoder().encode(titles).write(to: titlesURL, options: .atomic)
        for name in edits.remove {
            guard game?.id != name else { throw DSError.message("Close the game before removing it.") }
            let file = Self.roms.appending(path: name)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
        try FileManager.default.removeItem(at: request)
    }

    func importROMs(_ urls: [URL]) {
        busy = true
        let romDirectory = Self.roms
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    for url in urls {
                        let scope = url.startAccessingSecurityScopedResource()
                        defer { if scope { url.stopAccessingSecurityScopedResource() } }
                        guard url.pathExtension.lowercased() == "nds" else { throw DSError.message("Choose an uncompressed .nds ROM file.") }
                        let handle = try FileHandle(forReadingFrom: url)
                        defer { try? handle.close() }
                        let size = try handle.seekToEnd()
                        try handle.seek(toOffset: 0)
                        let header = try handle.read(upToCount: 512) ?? Data()
                        guard size >= 512, size <= 512 * 1024 * 1024, header.count == 512 else {
                            throw DSError.message("This file is not a valid DS ROM.")
                        }
                        func word(_ offset: Int) -> UInt64 { (0..<4).reduce(0) { $0 | UInt64(header[offset + $1]) << ($1 * 8) } }
                        for base in [0x20, 0x30] {
                            guard word(base) >= 512, word(base + 12) > 0, word(base) + word(base + 12) <= size else {
                                throw DSError.message("The DS ROM header is invalid or the file is incomplete.")
                            }
                        }
                        let destination = romDirectory.appending(path: url.lastPathComponent)
                        if destination.standardizedFileURL == url.standardizedFileURL { continue }
                        guard !FileManager.default.fileExists(atPath: destination.path) else {
                            throw DSError.message("\(url.lastPathComponent) is already imported. Your existing ROM and saves were kept.")
                        }
                        let temp = romDirectory.appending(path: UUID().uuidString + ".importing")
                        do { try FileManager.default.copyItem(at: url, to: temp); try FileManager.default.moveItem(at: temp, to: destination) }
                        catch { try? FileManager.default.removeItem(at: temp); throw error }
                    }
                }.value
            } catch { self.error = error.localizedDescription }
            refreshLibrary(); busy = false
        }
    }

    func play(_ game: DSGame) {
        guard !busy else { return }
        pause()
        resumeAfterLoad = true
        busy = true; error = nil; top = nil; bottom = nil
        self.game = game
        let system = Self.system.path, saves = Self.saves.path
        let auto = stateURL(game, slot: "auto").path
        worker.queue.async { [worker, weak self] in
            worker.pause()
            if let old = worker.current { _ = ds_save_state(old.path) }
            let loaded = ds_load(game.url.path, system, saves)
            if loaded {
                worker.current = URL(fileURLWithPath: auto)
                if FileManager.default.fileExists(atPath: auto) { _ = ds_load_state(auto) }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                if loaded {
                    self.recordOpened(game)
                    if self.resumeAfterLoad { self.resume() }
                }
                else { self.error = "The emulator could not load this ROM."; self.game = nil }
            }
        }
    }

    func resume() {
        guard game != nil, !busy else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            if audio == nil {
                let engine = AVAudioEngine()
                let format = AVAudioFormat(standardFormatWithSampleRate: 32768, channels: 2)!
                let source = AVAudioSourceNode(format: format) { _, _, count, buffers in
                    let list = UnsafeMutableAudioBufferListPointer(buffers)
                    if list.count >= 2, let l = list[0].mData, let r = list[1].mData {
                        ds_audio(l.assumingMemoryBound(to: Float.self), r.assumingMemoryBound(to: Float.self), count)
                    }
                    return noErr
                }
                engine.attach(source); engine.connect(source, to: engine.mainMixerNode, format: format)
                audio = engine
            }
            try audio?.start()
        } catch { status = "Playing without audio: \(error.localizedDescription)" }
        UIApplication.shared.isIdleTimerDisabled = true
        paused = false
        worker.queue.async { [worker] in worker.startTimer() }
    }

    func pause() {
        resumeAfterLoad = false
        UIApplication.shared.isIdleTimerDisabled = false
        paused = true; audio?.pause(); ds_clear_input()
        worker.queue.async { [worker] in
            worker.pause()
            if let path = worker.current { _ = ds_save_state(path.path) }
        }
    }

    func close() { pause(); game = nil; top = nil; bottom = nil; worker.queue.async { [worker] in ds_stop(); worker.current = nil } }
    private func stateURL(_ game: DSGame, slot: String) -> URL { Self.saves.appending(path: game.id + "." + slot + ".state") }
    func state(load: Bool) {
        guard let game, !busy else { return }
        let path = stateURL(game, slot: "quick").path
        busy = true
        worker.queue.async { [weak self] in
            let ok = load ? ds_load_state(path) : ds_save_state(path)
            DispatchQueue.main.async {
                self?.busy = false
                if ok { self?.status = load ? "State loaded" : "State saved" }
                else { self?.error = load ? "No compatible quick-save state found." : "Could not save state." }
            }
        }
    }
}

enum DSError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}
