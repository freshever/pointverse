import CryptoKit
import Foundation

enum WatchSyncState: String, Codable, Sendable {
    case savedOnWatch, queued, transferring, acknowledged, rejected

    var displayName: String {
        switch self {
        case .savedOnWatch: "已保存到手表"
        case .queued: "等待同步"
        case .transferring: "正在同步"
        case .acknowledged: "已保存到 iPhone"
        case .rejected: "同步失败"
        }
    }
}

struct WatchCaptureManifest: Codable, Identifiable, Sendable {
    var id: UUID { captureID }
    let schemaVersion: Int
    let captureID: UUID
    let capturedAt: Date
    let localeIdentifier: String
    let durationMilliseconds: Int
    let byteCount: Int64
    let sha256: String
    var syncState: WatchSyncState
}

actor WatchCaptureStore {
    private let fileManager = FileManager.default
    private let root: URL

    init() {
        let support = try! fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        root = support.appendingPathComponent("PointVerseWatch", isDirectory: true)
    }

    func stagingURL(captureID: UUID) throws -> URL {
        let directory = root.appendingPathComponent("Staging", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(captureID.uuidString).tmp.m4a")
    }

    func commit(_ result: WatchAudioRecorder.Result) throws -> WatchCaptureManifest {
        let data = try Data(contentsOf: result.url, options: .mappedIfSafe)
        guard !data.isEmpty else { throw CocoaError(.fileWriteUnknown) }
        let directory = captureDirectory(result.captureID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let audioURL = directory.appendingPathComponent("audio.m4a")
        try fileManager.moveItem(at: result.url, to: audioURL)
        let manifest = WatchCaptureManifest(
            schemaVersion: 1,
            captureID: result.captureID,
            capturedAt: Date(),
            localeIdentifier: Locale.current.identifier,
            durationMilliseconds: result.durationMilliseconds,
            byteCount: Int64(data.count),
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            syncState: .savedOnWatch
        )
        try update(manifest)
        return manifest
    }

    func update(_ manifest: WatchCaptureManifest) throws {
        let directory = captureDirectory(manifest.captureID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
    }

    func allCaptures() throws -> [WatchCaptureManifest] {
        let captures = root.appendingPathComponent("Captures", isDirectory: true)
        guard let directories = try? fileManager.contentsOfDirectory(at: captures, includingPropertiesForKeys: nil) else { return [] }
        return directories.compactMap { try? Data(contentsOf: $0.appendingPathComponent("manifest.json")) }
            .compactMap { try? JSONDecoder().decode(WatchCaptureManifest.self, from: $0) }
            .sorted { $0.capturedAt > $1.capturedAt }
    }

    func audioURL(for manifest: WatchCaptureManifest) throws -> URL {
        let url = captureDirectory(manifest.captureID).appendingPathComponent("audio.m4a")
        guard fileManager.fileExists(atPath: url.path) else { throw CocoaError(.fileNoSuchFile) }
        return url
    }

    private func captureDirectory(_ id: UUID) -> URL {
        root.appendingPathComponent("Captures", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
    }
}
