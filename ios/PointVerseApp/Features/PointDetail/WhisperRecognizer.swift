import AVFoundation
import Foundation
import PointVerseKit
import whisper

actor WhisperRecognizer {
    private let registry: ModelRegistry
    private var contextHandle: WhisperContextHandle?
    private var loadedModelPath: String?

    init(registry: ModelRegistry) {
        self.registry = registry
    }

    func transcribe(audioURL: URL, localeIdentifier: String) async throws -> TranscriptionOutput {
        let manifest = ModelManifest.whisperBaseQ5
        guard await registry.isInstalled(manifest) else { throw PointVerseError.modelNotInstalled }
        let modelURL = await registry.installedURL(for: manifest)
        let whisperContext = try loadContext(modelURL: modelURL)
        let samples = try Self.decodeToWhisperSamples(audioURL)
        guard !samples.isEmpty else { throw PointVerseError.transcriptionFailed }

        var parameters = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        parameters.print_realtime = false
        parameters.print_progress = false
        parameters.print_timestamps = false
        parameters.print_special = false
        parameters.translate = false
        parameters.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.processorCount - 2)))
        parameters.no_context = true
        parameters.single_segment = false

        let language = Self.whisperLanguage(for: localeIdentifier)
        let status = language.withCString { pointer in
            parameters.language = pointer
            return samples.withUnsafeBufferPointer { buffer in
                whisper_full(whisperContext, parameters, buffer.baseAddress, Int32(buffer.count))
            }
        }
        guard status == 0 else { throw PointVerseError.transcriptionFailed }

        var text = ""
        for index in 0..<whisper_full_n_segments(whisperContext) {
            guard let segment = whisper_full_get_segment_text(whisperContext, index) else { continue }
            text += String(cString: segment)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw PointVerseError.transcriptionFailed }
        return TranscriptionOutput(text: text, modelID: manifest.id, modelSHA256: manifest.sha256)
    }

    private func loadContext(modelURL: URL) throws -> OpaquePointer {
        if loadedModelPath == modelURL.path, let contextHandle { return contextHandle.context }
        contextHandle = nil
        loadedModelPath = nil

        var parameters = whisper_context_default_params()
#if targetEnvironment(simulator)
        parameters.use_gpu = false
#else
        parameters.flash_attn = true
#endif
        guard let newContext = whisper_init_from_file_with_params(modelURL.path, parameters) else {
            PointVerseLog.transcription.error("Whisper context initialization failed after Core ML fallback")
            throw PointVerseError.transcriptionFailed
        }
        contextHandle = WhisperContextHandle(context: newContext)
        loadedModelPath = modelURL.path
        PointVerseLog.transcription.info("Whisper context loaded; optional Core ML encoder may have fallen back to GGML")
        return newContext
    }

    private static func whisperLanguage(for identifier: String) -> String {
        let normalized = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
        if normalized.hasPrefix("zh") { return "zh" }
        if normalized.hasPrefix("ja") { return "ja" }
        return "en"
    }

    private static func decodeToWhisperSamples(_ url: URL) throws -> [Float] {
        let sourceFile = try AVAudioFile(forReading: url)
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: sourceFile.processingFormat, to: outputFormat) else {
            throw PointVerseError.transcriptionFailed
        }

        let ratio = outputFormat.sampleRate / sourceFile.processingFormat.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(sourceFile.length) * ratio))
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: max(capacity, 1)) else {
            throw PointVerseError.transcriptionFailed
        }
        let inputProvider = AudioConverterInputProvider(file: sourceFile)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            inputProvider.next(status: inputStatus)
        }
        guard conversionError == nil, status != .error, let channel = output.floatChannelData?.pointee else {
            throw PointVerseError.transcriptionFailed
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

private final class WhisperContextHandle: @unchecked Sendable {
    let context: OpaquePointer

    init(context: OpaquePointer) {
        self.context = context
    }

    deinit {
        whisper_free(context)
    }
}

private final class AudioConverterInputProvider: @unchecked Sendable {
    private let file: AVAudioFile
    private let lock = NSLock()
    private var didProvideInput = false

    init(file: AVAudioFile) {
        self.file = file
    }

    func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }
        if didProvideInput {
            status.pointee = .endOfStream
            return nil
        }
        didProvideInput = true
        guard let input = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            status.pointee = .noDataNow
            return nil
        }
        do {
            try file.read(into: input)
            status.pointee = .haveData
            return input
        } catch {
            status.pointee = .noDataNow
            return nil
        }
    }
}
