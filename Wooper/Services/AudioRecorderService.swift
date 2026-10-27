import AVFoundation
import ActivityKit
import Foundation
import Speech
import UIKit

@Observable
final class AudioRecorderService {
    static let shared = AudioRecorderService()

    var isRecording = false
    var elapsedTime: TimeInterval = 0
    var audioLevels: [CGFloat] = []
    var lastError: String?
    var liveTranscript: String = ""

    private var audioEngine: AVAudioEngine?
    private var outputFile: AVAudioFile?
    private var backgroundTimer: DispatchSourceTimer?
    private var startTime: Date?
    private var currentFileURL: URL?
    private var activity: Activity<RecordingActivityAttributes>?
    private var lastLiveActivitySecond: Int = -1
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    // Live transcription
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    // Engine health
    private var inputFormat: AVAudioFormat?
    private var monoFormat: AVAudioFormat?
    private var lastBufferTime: Date?

    private let maxLevelSamples = 300

    private init() {
        // Listen for audio session interruptions (calls, notifications, other apps)
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        }

        // Listen for audio engine being stopped by the system
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name.AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleEngineConfigChange()
        }
    }

    @discardableResult
    func startRecording() -> Bool {
        lastError = nil
        liveTranscript = ""

        backgroundTaskID = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.lastError = "Background task expired"
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
        } catch {
            lastError = "Audio session: \(error.localizedDescription)"
            endBackgroundTask()
            return false
        }

        let fileName = "memo_\(Date.now.timeIntervalSince1970).m4a"
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fileURL = docs.appendingPathComponent(fileName)
        currentFileURL = fileURL

        do {
            let engine = AVAudioEngine()
            let inputNode = engine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            inputFormat = format

            let outputSettings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]

            let mono = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1)
            monoFormat = mono

            let file = try AVAudioFile(forWriting: fileURL, settings: outputSettings)
            outputFile = file

            // Start live transcription
            startLiveTranscription(format: format)

            installTap(on: engine, format: format, monoFormat: mono, file: file)

            engine.prepare()
            try engine.start()

            audioEngine = engine
            isRecording = true
            startTime = Date.now
            audioLevels = []
            lastLiveActivitySecond = -1
            lastBufferTime = Date.now

            startBackgroundTimer()
            startLiveActivity(title: "Recording")

            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.endBackgroundTask()
            }

            return true
        } catch {
            lastError = "Engine start: \(error.localizedDescription)"
            endBackgroundTask()
            return false
        }
    }

    private func installTap(on engine: AVAudioEngine, format: AVAudioFormat, monoFormat: AVAudioFormat?, file: AVAudioFile) {
        let inputNode = engine.inputNode
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }

            self.lastBufferTime = Date()

            // Feed buffer to speech recognizer
            self.recognitionRequest?.append(buffer)

            // Write to file (downmix to mono if needed)
            if format.channelCount > 1, let monoFormat {
                if let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength) {
                    monoBuffer.frameLength = buffer.frameLength
                    if let src = buffer.floatChannelData, let dst = monoBuffer.floatChannelData {
                        let frames = Int(buffer.frameLength)
                        let channels = Int(format.channelCount)
                        for i in 0..<frames {
                            var sum: Float = 0
                            for ch in 0..<channels { sum += src[ch][i] }
                            dst[0][i] = sum / Float(channels)
                        }
                    }
                    try? file.write(from: monoBuffer)
                }
            } else {
                try? file.write(from: buffer)
            }

            // RMS level for waveform
            if let channelData = buffer.floatChannelData {
                let frames = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<frames {
                    let s = channelData[0][i]
                    sum += s * s
                }
                let rms = sqrt(sum / Float(frames))
                let db = 20 * log10(max(rms, 0.000001))
                let level = CGFloat(max(0, min(1, (db + 40) / 35)))

                DispatchQueue.main.async {
                    if self.audioLevels.count >= self.maxLevelSamples {
                        self.audioLevels.removeFirst()
                    }
                    self.audioLevels.append(level)
                }
            }
        }
    }

    // MARK: - Interruption Handling

    private func handleInterruption(_ notification: Notification) {
        guard isRecording,
              let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            // Audio interrupted (call, Siri, etc.) — engine pauses automatically
            print("[Wooper] Audio interrupted")
        case .ended:
            // Interruption ended — restart the engine
            print("[Wooper] Interruption ended, restarting engine")
            let options = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            if AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) {
                restartEngine()
            } else {
                // Try to restart anyway
                restartEngine()
            }
        @unknown default:
            break
        }
    }

    private func handleEngineConfigChange() {
        guard isRecording else { return }
        print("[Wooper] Engine config changed, restarting")
        restartEngine()
    }

    private func restartEngine() {
        guard isRecording, let engine = audioEngine, let file = outputFile else { return }

        // Re-activate audio session
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(true)

        // Remove old tap and reinstall
        engine.inputNode.removeTap(onBus: 0)

        if let format = inputFormat {
            installTap(on: engine, format: format, monoFormat: monoFormat, file: file)
        }

        // Restart engine
        engine.prepare()
        do {
            try engine.start()
            print("[Wooper] Engine restarted successfully")
        } catch {
            print("[Wooper] Engine restart failed: \(error)")
            lastError = "Engine restart failed: \(error.localizedDescription)"
        }
    }

    private func endBackgroundTask() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }

    func stopRecording() -> (URL, TimeInterval)? {
        // Stop live transcription
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil

        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        outputFile = nil
        audioEngine = nil
        inputFormat = nil
        monoFormat = nil

        stopTimers()
        endBackgroundTask()

        let duration: TimeInterval
        if let start = startTime {
            duration = Date.now.timeIntervalSince(start)
        } else {
            duration = elapsedTime
        }
        let url = currentFileURL

        isRecording = false
        elapsedTime = 0
        startTime = nil

        stopLiveActivity()

        if let url {
            return (url, duration)
        }
        return nil
    }

    // MARK: - Live Transcription

    private var accumulatedTranscript: String = ""
    private var currentSegmentTranscript: String = ""

    private func startLiveTranscription(format: AVAudioFormat) {
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let speechRecognizer, speechRecognizer.isAvailable else { return }

        accumulatedTranscript = ""
        currentSegmentTranscript = ""
        beginRecognitionSegment()
    }

    private func beginRecognitionSegment() {
        guard let speechRecognizer, speechRecognizer.isAvailable, isRecording else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = false
        recognitionRequest = request

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                self.currentSegmentTranscript = text
                DispatchQueue.main.async {
                    self.liveTranscript = self.accumulatedTranscript
                        + (self.accumulatedTranscript.isEmpty ? "" : " ")
                        + text
                }
                if result.isFinal {
                    // Segment finished — accumulate and start a new one
                    self.accumulatedTranscript += (self.accumulatedTranscript.isEmpty ? "" : " ") + text
                    self.currentSegmentTranscript = ""
                    self.recognitionRequest = nil
                    self.recognitionTask = nil
                    self.beginRecognitionSegment()
                }
            }
            if let error, (result?.isFinal != true) {
                // Error (usually timeout) — accumulate what we have and restart
                if !self.currentSegmentTranscript.isEmpty {
                    self.accumulatedTranscript += (self.accumulatedTranscript.isEmpty ? "" : " ") + self.currentSegmentTranscript
                }
                self.currentSegmentTranscript = ""
                self.recognitionRequest = nil
                self.recognitionTask = nil
                print("[Wooper] Recognition segment ended: \(error.localizedDescription), restarting")
                self.beginRecognitionSegment()
            }
        }
    }

    // MARK: - Timers

    private func startBackgroundTimer() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self, self.isRecording, let start = self.startTime else { return }
            let elapsed = Date.now.timeIntervalSince(start)
            let second = Int(elapsed)

            // Check engine health — if no buffer received in 5s, try restarting
            if let lastBuffer = self.lastBufferTime,
               Date().timeIntervalSince(lastBuffer) > 5 {
                print("[Wooper] No audio buffers for 5s, restarting engine")
                DispatchQueue.main.async {
                    self.restartEngine()
                }
            }

            if second != self.lastLiveActivitySecond {
                self.lastLiveActivitySecond = second
                DispatchQueue.main.async {
                    self.elapsedTime = elapsed
                    self.updateLiveActivity()
                }
            }
        }
        timer.resume()
        backgroundTimer = timer
    }

    private func stopTimers() {
        backgroundTimer?.cancel()
        backgroundTimer = nil
    }

    // MARK: - Live Activity

    private func startLiveActivity(title: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            lastError = (lastError ?? "") + " | Live Activities disabled"
            return
        }

        let attributes = RecordingActivityAttributes(recordingTitle: title)
        let state = RecordingActivityAttributes.ContentState(
            elapsedSeconds: 0,
            isRecording: true,
            waveformLevels: [],
            transcriptionPreview: ""
        )

        do {
            activity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil),
                pushType: nil
            )
        } catch {
            lastError = (lastError ?? "") + " | Live Activity: \(error.localizedDescription)"
        }
    }

    private func updateLiveActivity() {
        let sampled: [Float] = {
            let target = 80
            guard audioLevels.count > target else {
                return audioLevels.map { Float($0) }
            }
            let step = Double(audioLevels.count) / Double(target)
            return (0..<target).map { i in
                Float(audioLevels[min(Int(Double(i) * step), audioLevels.count - 1)])
            }
        }()

        // Show last ~80 chars of transcript for the widget
        let preview: String = {
            if liveTranscript.count <= 80 { return liveTranscript }
            return "…" + String(liveTranscript.suffix(79))
        }()

        let state = RecordingActivityAttributes.ContentState(
            elapsedSeconds: Int(elapsedTime),
            isRecording: true,
            waveformLevels: sampled,
            transcriptionPreview: preview
        )
        Task {
            await activity?.update(.init(state: state, staleDate: nil))
        }
    }

    private func stopLiveActivity() {
        let finalState = RecordingActivityAttributes.ContentState(
            elapsedSeconds: Int(elapsedTime),
            isRecording: false,
            waveformLevels: [],
            transcriptionPreview: liveTranscript.count <= 80 ? liveTranscript : "…" + String(liveTranscript.suffix(79))
        )
        Task {
            await activity?.end(.init(state: finalState, staleDate: nil), dismissalPolicy: .immediate)
            activity = nil
        }
    }
}
