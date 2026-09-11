import CryptoKit
import Foundation

public actor AudioBlobStore: AudioBlobStoring {
    private let rootURL: URL
    private let fileManager: FileManager

    public init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    public static func applicationSupportRoot(fileManager: FileManager = .default) throws -> URL {
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support.appending(path: "PointVerse", directoryHint: .isDirectory)
    }

    public func stagingURL(operationID: UUID) throws -> URL {
        let directory = rootURL.appending(path: "staging", directoryHint: .isDirectory)
        try prepare(directory)
        return directory.appending(path: "\(operationID.uuidString).m4a.tmp")
    }

    public func commit(_ recording: RecordingResult, assetID: UUID) throws -> StoredAudio {
        let data = try Data(contentsOf: recording.temporaryURL, options: .mappedIfSafe)
        guard !data.isEmpty else { throw PointVerseError.audioCommitFailed }

        let relativePath = "blobs/audio/\(assetID.uuidString).m4a"
        let destination = rootURL.appending(path: relativePath)
        try prepare(destination.deletingLastPathComponent())
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw PointVerseError.audioCommitFailed
        }

        do {
            try fileManager.moveItem(at: recording.temporaryURL, to: destination)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var protectedURL = destination
            try protectedURL.setResourceValues(values)
        } catch {
            throw PointVerseError.audioCommitFailed
        }

        return StoredAudio(
            assetID: assetID,
            relativePath: relativePath,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            byteCount: Int64(data.count),
            durationMilliseconds: recording.durationMilliseconds
        )
    }

    public func url(for relativePath: String) throws -> URL {
        let candidate = rootURL.appending(path: relativePath).standardizedFileURL
        guard candidate.path.hasPrefix(rootURL.standardizedFileURL.path + "/"),
              fileManager.fileExists(atPath: candidate.path) else {
            throw PointVerseError.audioCommitFailed
        }
        return candidate
    }

    public func delete(relativePath: String) throws {
        let candidate = rootURL.appending(path: relativePath).standardizedFileURL
        guard candidate.path.hasPrefix(rootURL.standardizedFileURL.path + "/") else { return }
        if fileManager.fileExists(atPath: candidate.path) {
            try fileManager.removeItem(at: candidate)
        }
    }

    private func prepare(_ directory: URL) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try mutableDirectory.setResourceValues(values)
    }
}
