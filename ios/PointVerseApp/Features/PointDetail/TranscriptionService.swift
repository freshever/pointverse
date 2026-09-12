import Foundation
import PointVerseKit
import QwenAdapter
import Speech
import WhisperAdapter

actor TranscriptionService {
    private let repository: any PointRepository
    private let blobStore: any AudioBlobStoring
    private let recognizer: HybridSpeechRecognizer
    private let titleGenerator: QwenTitleGenerator

    init(repository: any PointRepository, blobStore: any AudioBlobStoring, recognizer: HybridSpeechRecognizer, titleGenerator: QwenTitleGenerator) {
        self.repository = repository
        self.blobStore = blobStore
        self.recognizer = recognizer
        self.titleGenerator = titleGenerator
    }

    func resumePending() async {
        guard let pointIDs = try? await repository.queuedTranscriptionPointIDs() else { return }
        for pointID in pointIDs { await transcribe(pointID: pointID) }
    }

    func deriveMissingTitles(languageIdentifier: String? = nil) async {
        guard let manifest = ModelSelection.selectedLanguageModel() else { return }
        let language = Self.titleLanguage(languageIdentifier)
        let derivationModelID = Self.derivationModelID(manifest: manifest, language: language)
        guard let pointIDs = try? await repository.pointIDsNeedingTitle(modelID: derivationModelID) else { return }
        PointVerseLog.transcription.info("Local-model title backfill requested for \(pointIDs.count, privacy: .public) points; preferred=\(manifest.id, privacy: .public)")
        for pointID in pointIDs { _ = await deriveTitle(pointID: pointID, languageIdentifier: language) }
    }

    @discardableResult
    func deriveTitle(pointID: PointID, languageIdentifier: String? = nil) async -> String? {
        do {
            let detail = try await repository.pointDetail(id: pointID)
            guard let transcript = detail.effectiveTranscript, !transcript.isEmpty else { return nil }
            let imageText = try await repository.images(pointID: pointID).enumerated().compactMap { index, image in
                guard let text = image.recognizedText, !text.isEmpty else { return nil }
                return "Photo \(index + 1): " + String(text.prefix(300))
            }.joined(separator: "\n")
            let conversation = try await repository.conversationMessages(pointID: pointID)
            let language = Self.titleLanguage(languageIdentifier)
            let title = try await titleGenerator.generateTitle(
                transcript: imageText.isEmpty ? transcript : "Attached photos:\n" + imageText + "\n\nVoice-note transcript:\n" + String(transcript.prefix(700)),
                conversation: conversation,
                localeIdentifier: language
            )
            guard let manifest = ModelSelection.selectedLanguageModel() else { return nil }
            try await repository.saveCandidateTitle(
                pointID: pointID,
                title: title,
                modelID: Self.derivationModelID(manifest: manifest, language: language),
                modelSHA256: manifest.sha256
            )
            PointVerseLog.transcription.info("Local-model title generated in \(language, privacy: .public): \(title, privacy: .public)")
            return title
        } catch PointVerseError.modelNotInstalled {
            PointVerseLog.transcription.info("No selected or fallback language model is installed; keeping rule title")
            return nil
        } catch {
            let nsError = error as NSError
            PointVerseLog.transcription.error("Local-model title generation failed: domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)")
            return nil
        }
    }

    private static func titleLanguage(_ requested: String?) -> String {
        let stored = requested ?? UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
        if stored == "system" || stored.isEmpty { return Locale.current.identifier }
        return stored
    }

    private static func derivationModelID(manifest: ModelManifest, language: String) -> String {
        let normalized = language.replacingOccurrences(of: "_", with: "-").lowercased()
        let suffix: String
        if normalized.hasPrefix("zh-hant") || normalized.hasPrefix("zh-tw") || normalized.hasPrefix("zh-hk") {
            suffix = "zh-hant"
        } else if normalized.hasPrefix("zh") {
            suffix = "zh-hans"
        } else if normalized.hasPrefix("ja") {
            suffix = "ja"
        } else {
            suffix = "en"
        }
        return manifest.id + "-title-" + suffix
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
            _ = await deriveTitle(pointID: pointID)
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

actor HybridSpeechRecognizer {
    private let registry: ModelRegistry
    private let whisper: WhisperRecognizer
    private let apple = OnDeviceSpeechRecognizer()

    init(registry: ModelRegistry) {
        self.registry = registry
        whisper = WhisperRecognizer(registry: registry)
    }

    func transcribe(audioURL: URL, localeIdentifier: String) async throws -> TranscriptionOutput {
        let manifest = ModelSelection.selectedSpeechModel()
        if await registry.isInstalled(manifest) {
            PointVerseLog.transcription.info("Using local Whisper model; language=\(localeIdentifier, privacy: .public)")
            return try await whisper.transcribe(audioURL: audioURL, localeIdentifier: localeIdentifier)
        }
        PointVerseLog.transcription.info("Whisper model is not installed; using Apple Speech; language=\(localeIdentifier, privacy: .public)")
        let text = try await apple.transcribe(audioURL: audioURL, localeIdentifier: localeIdentifier)
        return TranscriptionOutput(text: text, modelID: "apple-speech-on-device", modelSHA256: "system")
    }
}

actor ConversationVoiceInputService {
    private let recorder: SystemAudioRecorder
    private let blobStore: any AudioBlobStoring
    private let recognizer: HybridSpeechRecognizer
    private var isRecording = false
    private var localeIdentifier = Locale.current.identifier

    init(recorder: SystemAudioRecorder, blobStore: any AudioBlobStoring, recognizer: HybridSpeechRecognizer) {
        self.recorder = recorder
        self.blobStore = blobStore
        self.recognizer = recognizer
    }

    func start(localeIdentifier: String) async throws {
        guard !isRecording else { return }
        let url = try await blobStore.stagingURL(operationID: UUID())
        try await recorder.start(at: url)
        self.localeIdentifier = localeIdentifier
        isRecording = true
        PointVerseLog.transcription.info("Conversation voice input started; language=\(localeIdentifier, privacy: .public)")
    }

    func finish() async throws -> String {
        guard isRecording else { throw PointVerseError.audioCommitFailed }
        let recording = try await recorder.stop()
        isRecording = false
        defer { try? FileManager.default.removeItem(at: recording.temporaryURL) }
        let output = try await recognizer.transcribe(audioURL: recording.temporaryURL, localeIdentifier: localeIdentifier)
        PointVerseLog.transcription.info("Conversation voice input transcribed with model=\(output.modelID, privacy: .public)")
        return output.text
    }

    func cancel() async {
        await recorder.cancel()
        isRecording = false
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
        if normalized.isEmpty { return Locale.current }
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
