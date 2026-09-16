import Foundation
import PointVerseKit
import Speech

actor TranscriptionService {
    private let repository: any PointRepository
    private let blobStore: any AudioBlobStoring
    private let recognizer: OnDeviceSpeechRecognizer

    init(repository: any PointRepository, blobStore: any AudioBlobStoring, recognizer: OnDeviceSpeechRecognizer) {
        self.repository = repository
        self.blobStore = blobStore
        self.recognizer = recognizer
    }

    func resumePending() async {
        guard let pointIDs = try? await repository.queuedTranscriptionPointIDs() else { return }
        for pointID in pointIDs { await transcribe(pointID: pointID) }
    }

    func transcribe(pointID: PointID) async {
        do {
            let detail = try await repository.pointDetail(id: pointID)
            guard let audioPath = detail.audioRelativePath else { return }
            let audioURL = try await blobStore.url(for: audioPath)
            try await repository.markTranscriptionRunning(pointID: pointID)
            let text = try await recognizer.transcribe(audioURL: audioURL, localeIdentifier: detail.localeIdentifier)
            try await repository.saveTranscript(pointID: pointID, engineText: text, modelID: "apple-speech-on-device", modelSHA256: "system")
            try await saveRuleTitle(pointID: pointID, transcript: text)
            PointVerseLog.transcription.info("Apple Speech transcription completed")
        } catch let error as PointVerseError {
            try? await repository.failTranscription(pointID: pointID, error: error)
        } catch {
            try? await repository.failTranscription(pointID: pointID, error: .transcriptionFailed)
        }
    }

    private func saveRuleTitle(pointID: PointID, transcript: String) async throws {
        let compact = transcript.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return }
        let title = compact.count > 28 ? String(compact.prefix(28)) + "…" : compact
        try await repository.saveCandidateTitle(pointID: pointID, title: title, modelID: "rule-title-v1", modelSHA256: "builtin")
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
              recognizer.supportsOnDeviceRecognition else { throw PointVerseError.onDeviceRecognitionUnavailable }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        return try await withCheckedThrowingContinuation { continuation in
            let box = SpeechContinuation(continuation)
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                    box.finish(text.isEmpty ? .failure(PointVerseError.transcriptionFailed) : .success(text))
                } else if error != nil {
                    box.finish(.failure(PointVerseError.transcriptionFailed))
                }
            }
            box.setTask(task)
        }
#endif
    }

    private func authorizationStatus() async -> SFSpeechRecognizerAuthorizationStatus {
        if SFSpeechRecognizer.authorizationStatus() != .notDetermined { return SFSpeechRecognizer.authorizationStatus() }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    private static func supportedLocale(from identifier: String) -> Locale {
        let value = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
        if value.hasPrefix("zh-hant") || value.hasPrefix("zh-tw") || value.hasPrefix("zh-hk") { return Locale(identifier: "zh-TW") }
        if value.hasPrefix("zh") { return Locale(identifier: "zh-CN") }
        if value.hasPrefix("ja") { return Locale(identifier: "ja-JP") }
        if value.hasPrefix("en") { return Locale(identifier: "en-US") }
        return Locale.current
    }
}

private final class SpeechContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, any Error>?
    private var task: SFSpeechRecognitionTask?
    init(_ continuation: CheckedContinuation<String, any Error>) { self.continuation = continuation }
    func setTask(_ task: SFSpeechRecognitionTask) {
        lock.lock()
        if continuation == nil { lock.unlock(); task.cancel(); return }
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
