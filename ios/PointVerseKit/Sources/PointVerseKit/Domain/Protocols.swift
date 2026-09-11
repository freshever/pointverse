import Foundation

public protocol AudioRecording: Sendable {
    func start(at temporaryURL: URL) async throws
    func stop() async throws -> RecordingResult
    func cancel() async
}

public protocol AudioBlobStoring: Sendable {
    func stagingURL(operationID: UUID) async throws -> URL
    func commit(_ recording: RecordingResult, assetID: UUID) async throws -> StoredAudio
    func url(for relativePath: String) async throws -> URL
    func delete(relativePath: String) async throws
}

public protocol PointRepository: Sendable {
    func migrate() async throws
    func commitVoiceCapture(_ command: VoiceCaptureCommand) async throws -> PointID
    func listPoints(matching query: String) async throws -> [PointSummary]
    func pointDetail(id: PointID) async throws -> PointDetail
    func queuedTranscriptionPointIDs() async throws -> [PointID]
    func pointIDsNeedingTitle(modelID: String) async throws -> [PointID]
    func markTranscriptionRunning(pointID: PointID) async throws
    func saveTranscript(pointID: PointID, engineText: String, modelID: String, modelSHA256: String) async throws
    func saveCandidateTitle(pointID: PointID, title: String, modelID: String, modelSHA256: String) async throws
    func conversationMessages(pointID: PointID) async throws -> [ConversationMessage]
    func appendConversationMessage(pointID: PointID, role: String, text: String) async throws
    func images(pointID: PointID) async throws -> [PointImage]
    func deletePoint(id: PointID) async throws -> String
    func saveUserTranscript(pointID: PointID, userText: String) async throws
    func failTranscription(pointID: PointID, error: PointVerseError) async throws
}
