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

@Test func textPointPersistsWithoutAudioAndIsSearchable() async throws {
    let database = try PointDatabase(inMemory: true)
    try await database.migrate()
    let pointID = try await database.commitTextPoint(text: "模拟器上的第一颗文本星星", createdAt: Date())
    let detail = try await database.pointDetail(id: pointID)
    #expect(detail.modality == "text")
    #expect(detail.sourceText == "模拟器上的第一颗文本星星")
    #expect(detail.audioRelativePath == nil)
    #expect(try await database.listPoints(matching: "文本星星").map(\.id) == [pointID])
    #expect(try await database.deletePoint(id: pointID) == nil)
}

@Test func starMapContentCombinesPointTextAndOCR() async throws {
    let database = try PointDatabase(inMemory: true)
    try await database.migrate()
    let pointID = try await database.commitTextPoint(text: "设计一个私人知识星图", createdAt: Date())
    try await database.addImage(
        pointID: pointID, id: UUID(), relativePath: "blobs/images/map.jpg",
        sha256: "abc", byteCount: 3, recognizedText: "相似想法彼此靠近"
    )
    let entry = try #require(try await database.pointMapEntries().first)
    #expect(entry.content.contains("私人知识星图"))
    #expect(entry.content.contains("相似想法彼此靠近"))
}

@Test func searchSupportsChineseSubstringsAndLiteralWildcards() async throws {
    let database = try PointDatabase(inMemory: true)
    try await database.migrate()
    let audio = StoredAudio(assetID: UUID(), relativePath: "blobs/audio/chinese.m4a", sha256: "abc", byteCount: 3, durationMilliseconds: 900)
    let pointID = try await database.commitVoiceCapture(
        VoiceCaptureCommand(operationID: UUID(), audio: audio, localeIdentifier: "zh-CN")
    )
    try await database.saveTranscript(
        pointID: pointID,
        engineText: "今天讨论本地语音模型和百分之百离线处理",
        modelID: "test",
        modelSHA256: "test-sha"
    )

    #expect(try await database.listPoints(matching: "语音模型").map(\.id) == [pointID])
    #expect(try await database.listPoints(matching: "%").isEmpty)
    #expect(try await database.listPoints(matching: "_").isEmpty)
}

@Test func conversationPersistsAndPointDeletionCascades() async throws {
    let database = try PointDatabase(inMemory: true)
    try await database.migrate()
    let audio = StoredAudio(assetID: UUID(), relativePath: "blobs/audio/delete.m4a", sha256: "abc", byteCount: 3, durationMilliseconds: 900)
    let pointID = try await database.commitVoiceCapture(VoiceCaptureCommand(operationID: UUID(), audio: audio))
    try await database.appendConversationMessage(pointID: pointID, role: "user", text: "还有什么可能？")
    try await database.appendConversationMessage(pointID: pointID, role: "assistant", text: "可以从另一个角度思考。")
    #expect(try await database.conversationMessages(pointID: pointID).count == 2)

    #expect(try await database.deletePoint(id: pointID) == "blobs/audio/delete.m4a")
    #expect(try await database.listPoints(matching: "").isEmpty)
    #expect(try await database.conversationMessages(pointID: pointID).isEmpty)
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
    try await database.saveTranscript(pointID: pointID, engineText: "context is also a point", modelID: "test", modelSHA256: "test-sha")

    let detail = try await database.pointDetail(id: pointID)
    #expect(detail.transcriptState == "succeeded")
    #expect(detail.transcriptErrorCode == nil)
    #expect(detail.effectiveTranscript == "context is also a point")
    #expect(detail.title == "context is also a po…")
    #expect(try await database.listPoints(matching: "context").map(\.id) == [pointID])
    #expect(try await database.listPoints(matching: "point").map(\.id) == [pointID])

    try await database.saveCandidateTitle(pointID: pointID, title: "Context Notes", modelID: "qwen-test", modelSHA256: "qwen-sha")
    #expect(try await database.pointDetail(id: pointID).title == "Context Notes")
}

@Test func embeddingQueueTracksRevisionAndRejectsStaleResults() async throws {
    let database = try PointDatabase(inMemory: true)
    try await database.migrate()
    let pointID = try await database.commitTextPoint(text: "想法之间会产生引力", createdAt: Date())
    let first = try #require(try await database.queuedEmbeddingDocuments(modelID: EmbeddingModelIdentity.bgeSmallZhV15).first)
    #expect(first.revision == 1)

    try await database.addImage(pointID: pointID, id: UUID(), relativePath: "blobs/images/a.jpg",
                                sha256: "image", byteCount: 10, recognizedText: "关系会随时间衰减")
    let current = try #require(try await database.queuedEmbeddingDocuments(modelID: EmbeddingModelIdentity.bgeSmallZhV15).last)
    #expect(current.revision == 2)
    #expect(current.text.contains("关系会随时间衰减"))

    try await database.saveEmbedding(.init(pointID: pointID, revision: first.revision,
                                           modelID: EmbeddingModelIdentity.bgeSmallZhV15, vector: [1, 0]))
    #expect(try await database.embeddings(modelID: EmbeddingModelIdentity.bgeSmallZhV15).isEmpty)
    try await database.saveEmbedding(.init(pointID: pointID, revision: current.revision,
                                           modelID: EmbeddingModelIdentity.bgeSmallZhV15, vector: [0.6, 0.8]))
    let stored = try #require(try await database.embeddings(modelID: EmbeddingModelIdentity.bgeSmallZhV15).first)
    #expect(stored.revision == 2)
    #expect(abs(stored.vector[0] - 0.6) < 0.001)
}

@Test func embeddingMathReturnsNearestPoints() {
    let a = PointID(), b = PointID(), c = PointID()
    let records = [
        PointEmbeddingRecord(pointID: a, revision: 1, modelID: "test", vector: [1, 0]),
        PointEmbeddingRecord(pointID: b, revision: 1, modelID: "test", vector: [0.8, 0.2]),
        PointEmbeddingRecord(pointID: c, revision: 1, modelID: "test", vector: [-1, 0]),
    ]
    let hits = EmbeddingMath.topK(query: [1, 0], records: records, excluding: a, limit: 2)
    #expect(hits.map(\.pointID) == [b, c])
}

@Test func e5ScoreCalibrationSeparatesBackgroundFromClearMatches() {
    #expect(EmbeddingMath.calibratedE5Score(0.84) == 0)
    #expect(EmbeddingMath.calibratedE5Score(0.85) > 0.37)
    #expect(EmbeddingMath.calibratedE5Score(0.8841) > 0.79)
    #expect(EmbeddingMath.calibratedE5Score(0.91) > 0.999)
}

@Test func relatedPointsReturnContentAndCoefficientInOrder() async throws {
    let database = try PointDatabase(inMemory: true)
    try await database.migrate()
    let source = try await database.commitTextPoint(text: "想法会随时间衰减")
    let close = try await database.commitTextPoint(text: "Ideas gradually decay over time")
    let far = try await database.commitTextPoint(text: "今晚吃红烧肉")
    let modelID = EmbeddingModelIdentity.multilingualE5Small
    try await database.saveEmbedding(.init(pointID: source, revision: 1, modelID: modelID, vector: [1, 0]))
    try await database.saveEmbedding(.init(pointID: close, revision: 1, modelID: modelID, vector: [0.9, 0.1]))
    try await database.saveEmbedding(.init(pointID: far, revision: 1, modelID: modelID, vector: [0, 1]))

    let related = try await database.relatedPoints(to: source, modelID: modelID, minimumScore: 0.85, limit: 5)
    #expect(related.map(\.id) == [close])
    #expect(related.first?.content == "Ideas gradually decay over time")
    #expect((related.first?.score ?? 0) > 0.99)
}
