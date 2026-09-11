import CryptoKit
import Foundation

public struct ModelManifest: Codable, Equatable, Sendable {
    public let id: String
    public let revision: String
    public let filename: String
    public let downloadURL: URL
    public let displayByteCount: Int64
    public let sha256: String
    public let license: String
    public let minimumFreeDiskBytes: Int64

    public init(id: String, revision: String, filename: String, downloadURL: URL, displayByteCount: Int64, sha256: String, license: String, minimumFreeDiskBytes: Int64) {
        self.id = id
        self.revision = revision
        self.filename = filename
        self.downloadURL = downloadURL
        self.displayByteCount = displayByteCount
        self.sha256 = sha256
        self.license = license
        self.minimumFreeDiskBytes = minimumFreeDiskBytes
    }

    public static let whisperBaseQ5 = ModelManifest(
        id: "whisper-base-q5_1",
        revision: "f281eb45af861ab5e5297d23694b7d46e090c02c",
        filename: "ggml-base-q5_1.bin",
        downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/f281eb45af861ab5e5297d23694b7d46e090c02c/ggml-base-q5_1.bin?download=true")!,
        displayByteCount: 59_700_000,
        sha256: "422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898",
        license: "MIT",
        minimumFreeDiskBytes: 150_000_000
    )

    public static let qwen3_0_6BQ8 = ModelManifest(
        id: "qwen3-0.6b-q8_0",
        revision: "23749fefcc72300e3a2ad315e1317431b06b590a",
        filename: "Qwen3-0.6B-Q8_0.gguf",
        downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen3-0.6B-GGUF/resolve/23749fefcc72300e3a2ad315e1317431b06b590a/Qwen3-0.6B-Q8_0.gguf?download=true")!,
        displayByteCount: 639_446_688,
        sha256: "9465e63a22add5354d9bb4b99e90117043c7124007664907259bd16d043bb031",
        license: "Apache-2.0",
        minimumFreeDiskBytes: 1_500_000_000
    )
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

    public func partialURL(for manifest: ModelManifest) -> URL {
        modelsDirectory.appending(path: manifest.filename + ".partial")
    }

    public func prepareForDownload(_ manifest: ModelManifest) throws -> URL {
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        var directory = modelsDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)

        let capacity = try modelsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
        guard capacity >= manifest.minimumFreeDiskBytes else { throw PointVerseError.insufficientDiskSpace }
        let partial = partialURL(for: manifest)
        if FileManager.default.fileExists(atPath: partial.path) { try FileManager.default.removeItem(at: partial) }
        return partial
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
        for url in [installedURL(for: manifest), partialURL(for: manifest)] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
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
