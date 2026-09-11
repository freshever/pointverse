import Foundation

public actor CaptureUseCase {
    private let recorder: any AudioRecording
    private let blobStore: any AudioBlobStoring
    private let repository: any PointRepository
    private var operationID: UUID?

    public init(recorder: any AudioRecording, blobStore: any AudioBlobStoring, repository: any PointRepository) {
        self.recorder = recorder
        self.blobStore = blobStore
        self.repository = repository
    }

    public func start() async throws {
        guard operationID == nil else {
            PointVerseLog.capture.notice("Ignored duplicate recording start")
            return
        }
        let operationID = UUID()
        let temporaryURL = try await blobStore.stagingURL(operationID: operationID)
        try await recorder.start(at: temporaryURL)
        self.operationID = operationID
        PointVerseLog.capture.info("Capture use case entered recording state")
    }

    public func finish(localeIdentifier: String = Locale.current.identifier) async throws -> PointID {
        guard let operationID else { throw PointVerseError.audioCommitFailed }
        let recording = try await recorder.stop()
        let audio = try await blobStore.commit(recording, assetID: UUID())
        do {
            let pointID = try await repository.commitVoiceCapture(
                VoiceCaptureCommand(operationID: operationID, audio: audio, localeIdentifier: localeIdentifier)
            )
            self.operationID = nil
            PointVerseLog.capture.info("Voice capture committed successfully")
            return pointID
        } catch {
            PointVerseLog.capture.error("Database commit failed; removing committed audio blob")
            try? await blobStore.delete(relativePath: audio.relativePath)
            throw PointVerseError.databaseCommitFailed
        }
    }

    public func cancel() async {
        await recorder.cancel()
        operationID = nil
        PointVerseLog.capture.info("Capture use case returned to idle after cancellation")
    }
}
