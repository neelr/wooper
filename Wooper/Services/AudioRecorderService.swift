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

    private let maxLevelSamples = 300

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
            let inputFormat = inputNode.outputFormat(forBus: 0)

            let outputSettings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: inputFormat.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]

            guard let monoFormat = AVAudioFormat(standardFormatWithSampleRate: inputFormat.sampleRate, channels: 1) else {
                lastError = "Could not create mono format"
                endBackgroundTask()
                return false
            }

            let file = try AVAudioFile(forWriting: fileURL, settings: outputSettings)
            outputFile = file

            // Start live transcription
            startLiveTranscription(format: inputFormat)

            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                guard let self else { return }

                // Feed buffer to speech recognizer
                self.recognitionRequest?.append(buffer)

                // Write to file (downmix to mono if needed)
                if inputFormat.channelCount > 1 {
                    if let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength) {
                        monoBuffer.frameLength = buffer.frameLength
                        if let src = buffer.floatChannelData, let dst = monoBuffer.floatChannelData {
                            let frames = Int(buffer.frameLength)
                            let channels = Int(inputFormat.channelCount)
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

            engine.prepare()
            try engine.start()

            audioEngine = engine
            isRecording = true
            startTime = Date.now
            audioLevels = []
            lastLiveActivitySecond = -1

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

    private func startLiveTranscription(format: AVAudioFormat) {
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let speechRecognizer, speechRecognizer.isAvailable else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = false
        recognitionRequest = request

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                DispatchQueue.main.async {
                    self.liveTranscript = result.bestTranscription.formattedString
                }
            }
            if error != nil || (result?.isFinal == true) {
                self.recognitionRequest = nil
                self.recognitionTask = nil
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
