import Foundation
import PointVerseKit
import Speech

actor TranscriptionService {
    private let repository: any PointRepository
    private let blobStore: any AudioBlobStoring
    private let recognizer: HybridSpeechRecognizer

    init(repository: any PointRepository, blobStore: any AudioBlobStoring, recognizer: HybridSpeechRecognizer) {
        self.repository = repository
        self.blobStore = blobStore
        self.recognizer = recognizer
    }

    func resumePending() async {
        guard let pointIDs = try? await repository.queuedTranscriptionPointIDs() else { return }
        for pointID in pointIDs { await transcribe(pointID: pointID) }
    }

    func transcribe(pointID: PointID) async {
        PointVerseLog.transcription.info("Transcription requested")
        do {
            let detail = try await repository.pointDetail(id: pointID)
            let audioURL = try await blobStore.url(for: detail.audioRelativePath)
            try await repository.markTranscriptionRunning(pointID: pointID)
            let output = try await recognizer.transcribe(
                audioURL: audioURL,
                localeIdentifier: detail.localeIdentifier
            )
            try await repository.saveTranscript(
                pointID: pointID,
                engineText: output.text,
                modelID: output.modelID,
                modelSHA256: output.modelSHA256
            )
            PointVerseLog.transcription.info("Transcription completed and persisted")
        } catch let error as PointVerseError {
            PointVerseLog.transcription.error("Transcription failed: \(error.rawValue, privacy: .public)")
            try? await repository.failTranscription(pointID: pointID, error: error)
        } catch {
            let nsError = error as NSError
            PointVerseLog.transcription.error("Transcription failed: domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)")
            try? await repository.failTranscription(pointID: pointID, error: .transcriptionFailed)
        }
    }
}

struct TranscriptionOutput: Sendable {
    let text: String
    let modelID: String
    let modelSHA256: String
}

actor HybridSpeechRecognizer {
    private let registry: ModelRegistry
    private let whisper: WhisperRecognizer
    private let apple = OnDeviceSpeechRecognizer()

    init(registry: ModelRegistry) {
        self.registry = registry
        whisper = WhisperRecognizer(registry: registry)
    }

    func transcribe(audioURL: URL, localeIdentifier: String) async throws -> TranscriptionOutput {
        if await registry.isInstalled(.whisperBaseQ5) {
            PointVerseLog.transcription.info("Using local Whisper model")
            return try await whisper.transcribe(audioURL: audioURL, localeIdentifier: localeIdentifier)
        }
        PointVerseLog.transcription.info("Whisper model is not installed; using Apple Speech")
        let text = try await apple.transcribe(audioURL: audioURL, localeIdentifier: localeIdentifier)
        return TranscriptionOutput(text: text, modelID: "apple-speech-on-device", modelSHA256: "system")
    }
}

final class OnDeviceSpeechRecognizer: @unchecked Sendable {
    func transcribe(audioURL: URL, localeIdentifier: String) async throws -> String {
#if targetEnvironment(simulator)
        throw PointVerseError.onDeviceRecognitionUnavailable
#else
        let authorization = await authorizationStatus()
        guard authorization == .authorized else { throw PointVerseError.transcriptionFailed }

        let locale = Self.supportedLocale(from: localeIdentifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            throw PointVerseError.onDeviceRecognitionUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true

        return try await withCheckedThrowingContinuation { continuation in
            let box = SpeechContinuation(continuation)
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.isEmpty {
                        box.finish(.failure(PointVerseError.transcriptionFailed))
                    } else {
                        box.finish(.success(text))
                    }
                } else if error != nil {
                    box.finish(.failure(PointVerseError.transcriptionFailed))
                }
            }
            box.setTask(task)
        }
#endif
    }

    private func authorizationStatus() async -> SFSpeechRecognizerAuthorizationStatus {
        if SFSpeechRecognizer.authorizationStatus() != .notDetermined {
            return SFSpeechRecognizer.authorizationStatus()
        }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    private static func supportedLocale(from identifier: String) -> Locale {
        let normalized = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
        if normalized.hasPrefix("zh-hant") || normalized.hasPrefix("zh-tw") || normalized.hasPrefix("zh-hk") {
            return Locale(identifier: "zh-TW")
        }
        if normalized.hasPrefix("zh") { return Locale(identifier: "zh-CN") }
        if normalized.hasPrefix("ja") { return Locale(identifier: "ja-JP") }
        return Locale(identifier: "en-US")
    }
}

private final class SpeechContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, any Error>?
    private var task: SFSpeechRecognitionTask?

    init(_ continuation: CheckedContinuation<String, any Error>) {
        self.continuation = continuation
    }

    func setTask(_ task: SFSpeechRecognitionTask) {
        lock.lock()
        if continuation == nil {
            lock.unlock()
            task.cancel()
            return
        }
        self.task = task
        lock.unlock()
    }

    func finish(_ result: Result<String, any Error>) {
        lock.lock()
        guard let continuation else { lock.unlock(); return }
        self.continuation = nil
        task = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}
