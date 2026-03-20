import AVFoundation
import Foundation

@Observable
final class AudioPlayerService: NSObject, AVAudioPlayerDelegate {
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var waveformSamples: [CGFloat] = []

    private var audioPlayer: AVAudioPlayer?
    private var updateTimer: Timer?
    private var onFinish: (() -> Void)?

    func loadAudio(url: URL) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)

            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.delegate = self
            audioPlayer?.prepareToPlay()
            duration = audioPlayer?.duration ?? 0
            currentTime = 0

            extractWaveform(url: url)
        } catch {
            print("Failed to load audio: \(error)")
        }
    }

    func play(onFinish: (() -> Void)? = nil) {
        self.onFinish = onFinish
        audioPlayer?.play()
        isPlaying = true
        startUpdating()
    }

    func pause() {
        audioPlayer?.pause()
        isPlaying = false
        updateTimer?.invalidate()
        updateTimer = nil
    }

    func togglePlayback(onFinish: (() -> Void)? = nil) {
        if isPlaying {
            pause()
        } else {
            play(onFinish: onFinish)
        }
    }

    func seek(to time: TimeInterval) {
        let clamped = max(0, min(duration, time))
        audioPlayer?.currentTime = clamped
        currentTime = clamped
    }

    func stop() {
        audioPlayer?.stop()
        isPlaying = false
        currentTime = 0
        updateTimer?.invalidate()
        updateTimer = nil
    }

    private func startUpdating() {
        updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self, let player = self.audioPlayer, player.isPlaying else { return }
            self.currentTime = player.currentTime
        }
    }

    private func extractWaveform(url: URL) {
        Task.detached { [weak self] in
            guard let samples = Self.readSamples(from: url, count: 200) else { return }
            await MainActor.run {
                self?.waveformSamples = samples
            }
        }
    }

    private static func readSamples(from url: URL, count: Int) -> [CGFloat]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let length = Int(file.length)
        guard length > 0 else { return nil }

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: file.fileFormat.sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(length)) else {
            return nil
        }

        do {
            try file.read(into: buffer)
        } catch {
            return nil
        }

        guard let channelData = buffer.floatChannelData?[0] else { return nil }
        let frameCount = Int(buffer.frameLength)
        let samplesPerBucket = max(1, frameCount / count)

        var result: [CGFloat] = []
        for i in 0..<count {
            let start = i * samplesPerBucket
            let end = min(start + samplesPerBucket, frameCount)
            if start >= frameCount { break }

            var peak: Float = 0
            for j in start..<end {
                peak = max(peak, abs(channelData[j]))
            }
            result.append(CGFloat(peak))
        }

        // Normalize to 0...1
        let maxPeak = result.max() ?? 1
        if maxPeak > 0 {
            result = result.map { $0 / maxPeak }
        }

        return result
    }

    // MARK: - AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        currentTime = 0
        updateTimer?.invalidate()
        updateTimer = nil
        onFinish?()
    }
}
