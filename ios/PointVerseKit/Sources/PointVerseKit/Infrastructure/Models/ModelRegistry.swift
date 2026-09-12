import CryptoKit
import Foundation

/// A process-wide permit that prevents two local ML runtimes from executing at
/// the same time. Every llama, whisper and diffusion entry point shares it.
public actor ModelExecutionGate {
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func acquire() async {
        if !occupied {
            occupied = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    public func release() {
        if waiters.isEmpty {
            occupied = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

public struct ModelManifest: Codable, Equatable, Sendable {
    public let id: String
    public let revision: String
    public let filename: String
    public let downloadURL: URL
    public let mirrorDownloadURLs: [URL]
    public let displayByteCount: Int64
    public let sha256: String
    public let license: String
    public let minimumFreeDiskBytes: Int64

    public init(id: String, revision: String, filename: String, downloadURL: URL, mirrorDownloadURLs: [URL] = [], displayByteCount: Int64, sha256: String, license: String, minimumFreeDiskBytes: Int64) {
        self.id = id
        self.revision = revision
        self.filename = filename
        self.downloadURL = downloadURL
        self.mirrorDownloadURLs = mirrorDownloadURLs
        self.displayByteCount = displayByteCount
        self.sha256 = sha256
        self.license = license
        self.minimumFreeDiskBytes = minimumFreeDiskBytes
    }

    public var downloadURLs: [URL] { mirrorDownloadURLs + [downloadURL] }

    public static let whisperBaseQ5 = ModelManifest(
        id: "whisper-base-q5_1",
        revision: "f281eb45af861ab5e5297d23694b7d46e090c02c",
        filename: "ggml-base-q5_1.bin",
        downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/f281eb45af861ab5e5297d23694b7d46e090c02c/ggml-base-q5_1.bin?download=true")!,
        mirrorDownloadURLs: [URL(string: "https://hf-mirror.com/ggerganov/whisper.cpp/resolve/f281eb45af861ab5e5297d23694b7d46e090c02c/ggml-base-q5_1.bin?download=true")!],
        displayByteCount: 59_700_000,
        sha256: "422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898",
        license: "MIT",
        minimumFreeDiskBytes: 150_000_000
    )

    public static let whisperTinyQ5 = ModelManifest(
        id: "whisper-tiny-q5_1",
        revision: "f281eb45af861ab5e5297d23694b7d46e090c02c",
        filename: "ggml-tiny-q5_1.bin",
        downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/f281eb45af861ab5e5297d23694b7d46e090c02c/ggml-tiny-q5_1.bin?download=true")!,
        mirrorDownloadURLs: [URL(string: "https://hf-mirror.com/ggerganov/whisper.cpp/resolve/f281eb45af861ab5e5297d23694b7d46e090c02c/ggml-tiny-q5_1.bin?download=true")!],
        displayByteCount: 32_152_673,
        sha256: "818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7",
        license: "MIT",
        minimumFreeDiskBytes: 100_000_000
    )

    public static let whisperSmallQ5 = ModelManifest(
        id: "whisper-small-q5_1",
        revision: "f281eb45af861ab5e5297d23694b7d46e090c02c",
        filename: "ggml-small-q5_1.bin",
        downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/f281eb45af861ab5e5297d23694b7d46e090c02c/ggml-small-q5_1.bin?download=true")!,
        mirrorDownloadURLs: [URL(string: "https://hf-mirror.com/ggerganov/whisper.cpp/resolve/f281eb45af861ab5e5297d23694b7d46e090c02c/ggml-small-q5_1.bin?download=true")!],
        displayByteCount: 190_085_487,
        sha256: "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb",
        license: "MIT",
        minimumFreeDiskBytes: 450_000_000
    )

    public static let qwen3_0_6BQ8 = ModelManifest(
        id: "qwen3-0.6b-q8_0",
        revision: "23749fefcc72300e3a2ad315e1317431b06b590a",
        filename: "Qwen3-0.6B-Q8_0.gguf",
        downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen3-0.6B-GGUF/resolve/23749fefcc72300e3a2ad315e1317431b06b590a/Qwen3-0.6B-Q8_0.gguf?download=true")!,
        mirrorDownloadURLs: [URL(string: "https://modelscope.cn/models/Qwen/Qwen3-0.6B-GGUF/resolve/master/Qwen3-0.6B-Q8_0.gguf")!],
        displayByteCount: 639_446_688,
        sha256: "9465e63a22add5354d9bb4b99e90117043c7124007664907259bd16d043bb031",
        license: "Apache-2.0",
        minimumFreeDiskBytes: 1_500_000_000
    )

    public static let qwen3_1_7BQ8 = ModelManifest(
        id: "qwen3-1.7b-q8_0",
        revision: "90862c4b9d2787eaed51d12237eafdfe7c5f6077",
        filename: "Qwen3-1.7B-Q8_0.gguf",
        downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen3-1.7B-GGUF/resolve/90862c4b9d2787eaed51d12237eafdfe7c5f6077/Qwen3-1.7B-Q8_0.gguf?download=true")!,
        mirrorDownloadURLs: [URL(string: "https://modelscope.cn/models/Qwen/Qwen3-1.7B-GGUF/resolve/master/Qwen3-1.7B-Q8_0.gguf")!],
        displayByteCount: 1_834_426_016,
        sha256: "061b54daade076b5d3362dac252678d17da8c68f07560be70818cace6590cb1a",
        license: "Apache-2.0",
        minimumFreeDiskBytes: 4_000_000_000
    )

    public static let stableDiffusion21Base6Bit = ModelManifest(
        id: "stable-diffusion-2.1-base-coreml-6bit",
        revision: "bf4734c9f67dc7b7f9ced335d1cee9a860bf3a85",
        filename: "stable-diffusion-2.1-base-coreml-6bit.zip",
        downloadURL: URL(string: "https://huggingface.co/apple/coreml-stable-diffusion-2-1-base-palettized/resolve/bf4734c9f67dc7b7f9ced335d1cee9a860bf3a85/coreml-stable-diffusion-2-1-base-palettized_split_einsum_v2_compiled.zip?download=true")!,
        mirrorDownloadURLs: [URL(string: "https://hf-mirror.com/apple/coreml-stable-diffusion-2-1-base-palettized/resolve/bf4734c9f67dc7b7f9ced335d1cee9a860bf3a85/coreml-stable-diffusion-2-1-base-palettized_split_einsum_v2_compiled.zip?download=true")!],
        displayByteCount: 1_140_000_000,
        sha256: "90c532943d460c559a8d84b7a0f05a4d265fee78ca355fdd5aa734fd43e08972",
        license: "OpenRAIL++",
        minimumFreeDiskBytes: 4_000_000_000
    )

    public static let qwen3VL2BQ8 = ModelManifest(
        id: "qwen3-vl-2b-q8_0",
        revision: "ea6a110",
        filename: "Qwen3-VL-2B-Instruct-Q8_0.gguf",
        downloadURL: URL(string: "https://huggingface.co/ggml-org/Qwen3-VL-2B-Instruct-GGUF/resolve/ea6a110/Qwen3-VL-2B-Instruct-Q8_0.gguf?download=true")!,
        mirrorDownloadURLs: [URL(string: "https://hf-mirror.com/ggml-org/Qwen3-VL-2B-Instruct-GGUF/resolve/ea6a110/Qwen3-VL-2B-Instruct-Q8_0.gguf?download=true")!],
        displayByteCount: 1_830_000_000,
        sha256: "b7802e29f71a9e5b5e3f83f613df898a2204342dcea71a231ea501d481813c39",
        license: "Apache-2.0",
        minimumFreeDiskBytes: 5_000_000_000
    )

    public static let qwen3VL2BProjectorQ8 = ModelManifest(
        id: "qwen3-vl-2b-mmproj-q8_0",
        revision: "ea6a110",
        filename: "mmproj-Qwen3-VL-2B-Instruct-Q8_0.gguf",
        downloadURL: URL(string: "https://huggingface.co/ggml-org/Qwen3-VL-2B-Instruct-GGUF/resolve/ea6a110/mmproj-Qwen3-VL-2B-Instruct-Q8_0.gguf?download=true")!,
        mirrorDownloadURLs: [URL(string: "https://hf-mirror.com/ggml-org/Qwen3-VL-2B-Instruct-GGUF/resolve/ea6a110/mmproj-Qwen3-VL-2B-Instruct-Q8_0.gguf?download=true")!],
        displayByteCount: 445_000_000,
        sha256: "69066c8f279ec85ff48ab4059f6ebba0d2932ca57667f2bbdac7d9805bca9e7b",
        license: "Apache-2.0",
        minimumFreeDiskBytes: 3_000_000_000
    )
}

public enum ModelSelection {
    public static let speechDefaultsKey = "selectedSpeechModelID"
    public static let languageDefaultsKey = "selectedLanguageModelID"
    public static let imageDefaultsKey = "selectedImageModelID"
    public static let disabledLanguageModelID = "disabled"
    public static let speechModels: [ModelManifest] = [.whisperTinyQ5, .whisperBaseQ5, .whisperSmallQ5]
    public static let languageModels: [ModelManifest] = [.qwen3_0_6BQ8, .qwen3_1_7BQ8]
    public static let imageModels: [ModelManifest] = [.stableDiffusion21Base6Bit]
    public static let visionModels: [ModelManifest] = [.qwen3VL2BQ8, .qwen3VL2BProjectorQ8]

    public static func selectedSpeechModel(defaults: UserDefaults = .standard) -> ModelManifest {
        let id = defaults.string(forKey: speechDefaultsKey) ?? ModelManifest.whisperBaseQ5.id
        return speechModels.first(where: { $0.id == id }) ?? .whisperBaseQ5
    }

    public static func selectedLanguageModel(defaults: UserDefaults = .standard) -> ModelManifest? {
        let id = defaults.string(forKey: languageDefaultsKey) ?? ModelManifest.qwen3_0_6BQ8.id
        guard id != disabledLanguageModelID else { return nil }
        return languageModels.first(where: { $0.id == id }) ?? .qwen3_0_6BQ8
    }

    public static func selectedImageModel(defaults: UserDefaults = .standard) -> ModelManifest {
        let id = defaults.string(forKey: imageDefaultsKey) ?? ModelManifest.stableDiffusion21Base6Bit.id
        return imageModels.first(where: { $0.id == id }) ?? .stableDiffusion21Base6Bit
    }
}

public actor ModelRegistry {
    public nonisolated let modelsDirectory: URL

    public init(rootURL: URL) {
        modelsDirectory = rootURL.appending(path: "models", directoryHint: .isDirectory)
    }

    public func isInstalled(_ manifest: ModelManifest) -> Bool {
        FileManager.default.fileExists(atPath: installedURL(for: manifest).path)
    }

    public func installedURL(for manifest: ModelManifest) -> URL {
        modelsDirectory.appending(path: manifest.filename)
    }

    public func resolveInstalledModel(preferred: ModelManifest, candidates: [ModelManifest]) -> ModelManifest? {
        if isInstalled(preferred) { return preferred }
        return candidates.first(where: { isInstalled($0) })
    }

    public func partialURL(for manifest: ModelManifest) -> URL {
        modelsDirectory.appending(path: manifest.filename + ".partial")
    }

    public func resumeDataURL(for manifest: ModelManifest) -> URL {
        modelsDirectory.appending(path: manifest.filename + ".resume")
    }

    public func prepareForDownload(_ manifest: ModelManifest) throws -> URL {
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        var directory = modelsDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)

        let capacity = try modelsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
        guard capacity >= manifest.minimumFreeDiskBytes else { throw PointVerseError.insufficientDiskSpace }
        return partialURL(for: manifest)
    }

    public func installPartial(_ manifest: ModelManifest) throws -> URL {
        let partial = partialURL(for: manifest)
        guard FileManager.default.fileExists(atPath: partial.path) else { throw PointVerseError.modelNotInstalled }
        let digest = try sha256(of: partial)
        guard digest == manifest.sha256.lowercased() else {
            PointVerseLog.storage.error("Model checksum mismatch")
            throw PointVerseError.modelChecksumMismatch
        }

        let destination = installedURL(for: manifest)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: partial, to: destination)
        var installed = destination
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try installed.setResourceValues(values)
        PointVerseLog.storage.info("Model verified and installed")
        return destination
    }

    public func remove(_ manifest: ModelManifest) throws {
        for url in [installedURL(for: manifest), partialURL(for: manifest), resumeDataURL(for: manifest)] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        if manifest.filename.hasSuffix(".zip") {
            let extracted = modelsDirectory
                .deletingLastPathComponent()
                .appending(path: "image-models/" + manifest.id, directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: extracted.path) {
                try FileManager.default.removeItem(at: extracted)
            }
        }
        PointVerseLog.storage.info("Model removed")
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 4 * 1_024 * 1_024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
