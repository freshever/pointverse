import CryptoKit
import Foundation

public actor ImageBlobStore {
    private let rootURL: URL
    private let fileManager: FileManager

    public init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    public func saveJPEG(_ data: Data, assetID: UUID) throws -> (relativePath: String, sha256: String, byteCount: Int64) {
        guard !data.isEmpty else { throw PointVerseError.databaseCommitFailed }
        let relativePath = "blobs/images/\(assetID.uuidString).jpg"
        let destination = rootURL.appending(path: relativePath)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
        var protectedURL = destination
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedURL.setResourceValues(values)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (relativePath, hash, Int64(data.count))
    }

    public func url(for relativePath: String) throws -> URL {
        let candidate = rootURL.appending(path: relativePath).standardizedFileURL
        guard candidate.path.hasPrefix(rootURL.standardizedFileURL.path + "/"),
              fileManager.fileExists(atPath: candidate.path) else { throw PointVerseError.databaseCommitFailed }
        return candidate
    }

    public func delete(relativePath: String) throws {
        let candidate = rootURL.appending(path: relativePath).standardizedFileURL
        guard candidate.path.hasPrefix(rootURL.standardizedFileURL.path + "/") else { return }
        if fileManager.fileExists(atPath: candidate.path) { try fileManager.removeItem(at: candidate) }
    }
}
