import Foundation
import PointVerseKit
import QwenAdapter
import WhisperAdapter
import Speech
import AVFoundation

actor TranscriptionService {
    static let didChangeNotification = Notification.Name("PointVerseTranscriptionDidChange")
    private let repository: any PointRepository
    private let blobStore: any AudioBlobStoring
    private let recognizer: OnDeviceSpeechRecognizer
    private let whisperRecognizer: WhisperRecognizer
    private let titleGenerator: QwenTitleGenerator
    private var cloudBaseURL: URL?
    private var cloudToken: String?

    func configureCloud(baseURL: URL?, accessToken: String?) {
        cloudBaseURL = baseURL; cloudToken = accessToken
    }

    init(repository: any PointRepository, blobStore: any AudioBlobStoring, recognizer: OnDeviceSpeechRecognizer, whisperRecognizer: WhisperRecognizer, titleGenerator: QwenTitleGenerator) {
        self.repository = repository
        self.blobStore = blobStore
        self.recognizer = recognizer
        self.whisperRecognizer = whisperRecognizer
        self.titleGenerator = titleGenerator
    }

    func transcribeCandidate(pointID: PointID, modelID: String) async throws {
        let detail = try await repository.pointDetail(id: pointID)
        guard let audioPath = detail.audioRelativePath else { throw PointVerseError.audioDecodeFailed }
        let audioURL = try await blobStore.url(for: audioPath)
        let output: TranscriptionOutput
        if modelID.hasPrefix("pointverse-cloud-whisper-") {
            output = try await recognizeInCloud(audioURL: audioURL)
        } else if modelID == "apple-speech-on-device" {
            let text = try await recognizer.transcribe(audioURL: audioURL, localeIdentifier: detail.localeIdentifier)
            output = TranscriptionOutput(text: text, modelID: modelID, modelSHA256: "system")
        } else {
            guard let manifest = ModelSelection.speechModels.first(where: { $0.id == modelID }) else {
                throw PointVerseError.modelNotInstalled
            }
            output = try await whisperRecognizer.transcribe(audioURL: audioURL, localeIdentifier: detail.localeIdentifier, manifest: manifest)
        }
        try await repository.saveTranscriptionCandidate(pointID: pointID, text: output.text, modelID: output.modelID,
                                                        modelSHA256: output.modelSHA256, select: true)
        // Always make the newly selected transcript visible as a title at
        // once. The optional language model may be unavailable or slow; it can
        // replace this deterministic title when it finishes.
        try await saveRuleTitle(pointID: pointID, transcript: output.text)
        await notifyChange(pointID)
        _ = await deriveTitle(pointID: pointID)
        await notifyChange(pointID)
    }

    func resumePending() async {
        guard let pointIDs = try? await repository.queuedTranscriptionPointIDs() else { return }
        for pointID in pointIDs {
            await transcribe(pointID: pointID, generateAITitle: !AppNetworkPolicy.allowsCloud())
        }
    }

    func transcribe(pointID: PointID, generateAITitle: Bool = true) async {
        do {
            let detail = try await repository.pointDetail(id: pointID)
            guard let audioPath = detail.audioRelativePath else { return }
            let audioURL = try await blobStore.url(for: audioPath)
            try await repository.markTranscriptionRunning(pointID: pointID)
            await notifyChange(pointID)
            let output: TranscriptionOutput
            let useCloud = generateAITitle && AppNetworkPolicy.allowsCloud() &&
                UserDefaults.standard.string(forKey: "selectedExternalModel.speech") != "local"
            if useCloud {
                do { output = try await recognizeInCloud(audioURL: audioURL) }
                catch {
                    guard UserDefaults.standard.bool(forKey: AppNetworkPolicy.offlineBackupKey),
                          AppNetworkPolicy.isOfflineFailure(error) else { throw error }
                    let text = try await recognizer.transcribe(audioURL: audioURL, localeIdentifier: detail.localeIdentifier)
                    output = .init(text: text, modelID: "apple-speech-on-device", modelSHA256: "system")
                }
            } else {
                let text = try await recognizer.transcribe(audioURL: audioURL, localeIdentifier: detail.localeIdentifier)
                output = .init(text: text, modelID: "apple-speech-on-device", modelSHA256: "system")
            }
            let text = output.text
            UserDefaults.standard.set(output.modelID.hasPrefix("pointverse-cloud-whisper-") ? "cloud" : "local", forKey: "pointverse.lastAIExecution")
            try await repository.saveTranscript(pointID: pointID, engineText: text, modelID: output.modelID, modelSHA256: output.modelSHA256)
            // The transcript is ready for display now. Title derivation can take
            // considerably longer and must not keep the UI in its running state.
            await notifyChange(pointID)
            try await saveRuleTitle(pointID: pointID, transcript: text)
            PointVerseLog.transcription.info("Speech transcription completed")
            // Semantic indexing can start as soon as transcription returns.
            // The slower local-LLM title pass continues independently.
            if generateAITitle { Task {
                _ = await self.deriveTitle(pointID: pointID)
                await self.notifyChange(pointID)
            } }
        } catch let error as PointVerseError {
            try? await repository.failTranscription(pointID: pointID, error: error)
            await notifyChange(pointID)
        } catch {
            try? await repository.failTranscription(pointID: pointID, error: .transcriptionFailed)
            await notifyChange(pointID)
        }
    }

    private func notifyChange(_ pointID: PointID) async {
        await MainActor.run {
            NotificationCenter.default.post(
                name: Self.didChangeNotification,
                object: pointID.rawValue.uuidString
            )
        }
    }

    private func recognizeInCloud(audioURL: URL) async throws -> TranscriptionOutput {
        try AppNetworkPolicy.requireCloud()
        guard let cloudBaseURL, let cloudToken else {
            throw ExternalModelConnectionError.server(status: 401, message: "请先登录点界账户。")
        }
        let file = try AVAudioFile(forReading: audioURL)
        let totalSeconds = Double(file.length) / file.processingFormat.sampleRate
        guard totalSeconds > 0, totalSeconds <= 1800 else {
            throw ExternalModelConnectionError.server(status: 413, message: "云端转写支持30分钟以内的录音。")
        }
        var texts: [String] = []
        var models = Set<String>()
        for index in 0..<Int(ceil(totalSeconds / 120)) {
            try Task.checkCancellation()
            let wav = try Self.cloudWAV(audioURL, startSeconds: Double(index) * 120)
            var request = URLRequest(url: cloudBaseURL.appending(path: "v1/ai/audio/transcriptions"))
            request.httpMethod = "POST"; request.timeoutInterval = 150
            request.setValue("Bearer " + cloudToken, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["audio": wav.base64EncodedString()])
            let (data, response) = try await NetworkModelRequestExecutor.perform(request, maximumAttempts: 1)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = object["text"] as? String else { throw PointVerseError.transcriptionFailed }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { texts.append(text) }
            models.insert((object["model"] as? String) ?? "server-managed")
        }
        guard !texts.isEmpty else { throw PointVerseError.transcriptionFailed }
        UserDefaults.standard.set("cloud", forKey: "pointverse.lastAIExecution")
        return .init(text: texts.joined(separator: "\n"), modelID: "pointverse-cloud-" + models.sorted().joined(separator: "/"), modelSHA256: "server-managed")
    }

    private static func cloudWAV(_ url: URL, startSeconds: Double = 0) throws -> Data {
        let file = try AVAudioFile(forReading: url)
        let totalSeconds = Double(file.length) / file.processingFormat.sampleRate
        let seconds = min(120, totalSeconds - startSeconds)
        guard seconds > 0, totalSeconds <= 1800, file.processingFormat.channelCount <= 2,
              (8000...96000).contains(file.processingFormat.sampleRate) else {
            throw ExternalModelConnectionError.server(status: 413, message: "云端转写支持30分钟以内的录音。")
        }
        let startFrame = AVAudioFramePosition(startSeconds * file.processingFormat.sampleRate)
        file.framePosition = startFrame
        let frameCount = AVAudioFrameCount(min(file.length - startFrame, AVAudioFramePosition(120 * file.processingFormat.sampleRate)))
        guard let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount),
              let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: file.processingFormat, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(ceil(seconds * 16000) + 32)) else {
            throw PointVerseError.audioDecodeFailed
        }
        try file.read(into: source, frameCount: frameCount)
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .endOfStream; return nil }
            supplied = true; state.pointee = .haveData; return source
        }
        guard status != .error, error == nil, output.frameLength > 0, let pcm = output.int16ChannelData?[0] else {
            throw PointVerseError.audioDecodeFailed
        }
        let count = Int(output.frameLength) * 2
        var wav = Data()
        func text(_ value: String) { wav.append(contentsOf: value.utf8) }
        func u32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { wav.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { wav.append(contentsOf: $0) } }
        text("RIFF"); u32(UInt32(36 + count)); text("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
        text("data"); u32(UInt32(count)); wav.append(Data(bytes: pcm, count: count))
        return wav
    }

    func deriveMissingTitles(languageIdentifier: String? = nil) async {
        guard let manifest = ModelSelection.selectedLanguageModel() else { return }
        let language = Self.titleLanguage(languageIdentifier)
        let modelID = Self.derivationModelID(manifest: manifest, language: language)
        guard let pointIDs = try? await repository.pointIDsNeedingTitle(modelID: modelID) else { return }
        for pointID in pointIDs { _ = await deriveTitle(pointID: pointID, languageIdentifier: language) }
    }

    @discardableResult
    func deriveTitle(pointID: PointID, languageIdentifier: String? = nil) async -> String? {
        do {
            let detail = try await repository.pointDetail(id: pointID)
            let primaryText = detail.modality == "text" ? detail.sourceText : detail.effectiveTranscript
            let audioUnderstanding = try await repository.audioUnderstanding(pointID: pointID)
            guard primaryText?.isEmpty == false || audioUnderstanding != nil else { return nil }
            let imageText = try await repository.images(pointID: pointID).enumerated().compactMap { index, image in
                guard let text = image.recognizedText, !text.isEmpty else { return nil }
                return "Photo \(index + 1): " + String(text.prefix(300))
            }.joined(separator: "\n")
            let conversation = try await repository.conversationMessages(pointID: pointID)
            let language = Self.titleLanguage(languageIdentifier)
            let savedText = primaryText ?? ""
            var context = imageText.isEmpty
                ? savedText
                : "Attached photos:\n\(imageText)\n\nSaved content:\n\(String(savedText.prefix(700)))"
            if let audioUnderstanding {
                context += "\n\nMusic and sound analysis:\n" + audioUnderstanding.semanticText
            }
            let title = try await titleGenerator.generateTitle(
                transcript: context,
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
            return title
        } catch {
            return nil
        }
    }

    private static func titleLanguage(_ requested: String?) -> String {
        let stored = requested ?? UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
        return stored == "system" || stored.isEmpty ? Locale.current.identifier : stored
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
