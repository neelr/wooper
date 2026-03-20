import Speech

enum TranscriptionService {
    static func transcribe(url: URL) async throws -> String {
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer, recognizer.isAvailable else {
            throw NSError(domain: "TranscriptionService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Speech recognizer unavailable"])
        }

        // Request authorization
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard status == .authorized else {
            throw NSError(domain: "TranscriptionService", code: 2, userInfo: [NSLocalizedDescriptionKey: "Speech recognition not authorized"])
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = false // Use server-side for better accuracy

        return try await withCheckedThrowingContinuation { continuation in
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let result, result.isFinal {
                    continuation.resume(returning: result.bestTranscription.formattedString)
                }
            }
        }
    }
}
