import CryptoKit
import PointVerseKit
import UIKit
import WatchConnectivity

@MainActor
final class BackgroundSessionEvents {
    static let shared = BackgroundSessionEvents()
    private var handlers: [String: () -> Void] = [:]

    func store(identifier: String, handler: @escaping () -> Void) {
        handlers[identifier] = handler
    }

    func finish(identifier: String) {
        handlers.removeValue(forKey: identifier)?()
    }
}

final class PointVerseAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            BackgroundSessionEvents.shared.store(identifier: identifier, handler: completionHandler)
        }
    }
}

private struct ReceivedWatchCaptureManifest: Codable, Sendable {
    let schemaVersion: Int
    let captureID: UUID
    let capturedAt: Date
    let localeIdentifier: String
    let durationMilliseconds: Int
    let byteCount: Int64
    let sha256: String
}

final class PhoneWatchTransferReceiver: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = PhoneWatchTransferReceiver()

    private let session = WCSession.default
    private let lock = NSLock()
    private var database: PointDatabase?
    private var blobStore: AudioBlobStore?
    private var transcriptionService: TranscriptionService?

    func configure(database: PointDatabase, blobStore: AudioBlobStore, transcriptionService: TranscriptionService) {
        lock.withLock {
            self.database = database
            self.blobStore = blobStore
            self.transcriptionService = transcriptionService
        }
        guard WCSession.isSupported() else { return }
        session.delegate = self
        session.activate()
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let manifestData = file.metadata?["manifest"] as? Data,
              let manifest = try? JSONDecoder().decode(ReceivedWatchCaptureManifest.self, from: manifestData) else {
            PointVerseLog.storage.error("Rejected Watch capture with invalid metadata")
            return
        }

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-\(manifest.captureID.uuidString).m4a")
        do {
            if FileManager.default.fileExists(atPath: temporaryURL.path) {
                try FileManager.default.removeItem(at: temporaryURL)
            }
            try FileManager.default.copyItem(at: file.fileURL, to: temporaryURL)
        } catch {
            PointVerseLog.storage.error("Failed to preserve received Watch audio")
            return
        }

        let dependencies = lock.withLock { (database, blobStore, transcriptionService) }
        guard let database = dependencies.0, let blobStore = dependencies.1,
              let transcriptionService = dependencies.2 else { return }

        Task {
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            do {
                if UserDefaults.standard.bool(forKey: "watchCaptureReceived.\(manifest.captureID.uuidString)") {
                    self.session.transferUserInfo(["acknowledgedCaptureID": manifest.captureID.uuidString])
                    return
                }
                let data = try Data(contentsOf: temporaryURL, options: .mappedIfSafe)
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard Int64(data.count) == manifest.byteCount, digest == manifest.sha256 else {
                    throw PointVerseError.audioCommitFailed
                }
                let audio = try await blobStore.commit(
                    RecordingResult(temporaryURL: temporaryURL, durationMilliseconds: manifest.durationMilliseconds),
                    assetID: UUID()
                )
                let pointID = try await database.commitVoiceCapture(
                    VoiceCaptureCommand(
                        operationID: manifest.captureID,
                        audio: audio,
                        localeIdentifier: manifest.localeIdentifier,
                        createdAt: manifest.capturedAt
                    )
                )
                UserDefaults.standard.set(true, forKey: "watchCaptureReceived.\(manifest.captureID.uuidString)")
                self.session.transferUserInfo(["acknowledgedCaptureID": manifest.captureID.uuidString])
                await transcriptionService.transcribe(pointID: pointID)
                PointVerseLog.storage.info("Watch capture imported successfully")
            } catch {
                let nsError = error as NSError
                PointVerseLog.storage.error("Watch capture import failed: domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)")
            }
        }
    }
}
