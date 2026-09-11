import Foundation
import Testing
@testable import PointVerseKit

@Test func repeatedOperationIsIdempotent() async throws {
    let database = try PointDatabase(inMemory: true)
    try await database.migrate()
    let operationID = UUID()
    let audio = StoredAudio(assetID: UUID(), relativePath: "blobs/audio/a.m4a", sha256: "abc", byteCount: 3, durationMilliseconds: 100)
    let first = try await database.commitVoiceCapture(VoiceCaptureCommand(operationID: operationID, audio: audio))
    let secondAudio = StoredAudio(assetID: UUID(), relativePath: "blobs/audio/b.m4a", sha256: "def", byteCount: 3, durationMilliseconds: 100)
    let second = try await database.commitVoiceCapture(VoiceCaptureCommand(operationID: operationID, audio: secondAudio))
    #expect(first == second)
    #expect(try await database.listPoints(matching: "").count == 1)
}

@Test func draftRejectsFieldsOutsidePOCContract() {
    #expect(throws: PointVerseError.invalidModelOutput) {
        try PointDraft(title: String(repeating: "点", count: 21), summary: "摘要", tags: [], nextQuestion: nil)
    }
}

@Test func transcriptPersistsAndBecomesSearchable() async throws {
    let database = try PointDatabase(inMemory: true)
    try await database.migrate()
    let audio = StoredAudio(assetID: UUID(), relativePath: "blobs/audio/search.m4a", sha256: "abc", byteCount: 3, durationMilliseconds: 900)
    let pointID = try await database.commitVoiceCapture(
        VoiceCaptureCommand(operationID: UUID(), audio: audio, localeIdentifier: "en-US")
    )
    try await database.markTranscriptionRunning(pointID: pointID)
    try await database.saveTranscript(pointID: pointID, engineText: "context is also a point")

    let detail = try await database.pointDetail(id: pointID)
    #expect(detail.transcriptState == "succeeded")
    #expect(detail.transcriptErrorCode == nil)
    #expect(detail.effectiveTranscript == "context is also a point")
    #expect(try await database.listPoints(matching: "context").map(\.id) == [pointID])
}
