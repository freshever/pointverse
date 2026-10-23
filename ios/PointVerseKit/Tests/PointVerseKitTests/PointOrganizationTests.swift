import Foundation
import Testing
@testable import PointVerseKit

@Test func cleanupOnlySuggestsExactDuplicatesAndNeverRejectsShortOrMediaNotes() {
    func record(_ text: String, seconds: Double, media: Bool = false, conversation: Bool = false) -> PointOrganizationRecord {
        .init(entry: .init(point: .init(id: PointID(), title: "", createdAt: Date(timeIntervalSince1970: seconds), transcriptState: nil),
                          content: text, localeIdentifier: "zh-CN"), revision: 1, hasMedia: media, hasConversation: conversation)
    }
    let original = record("保留这个想法", seconds: 1)
    let duplicate = record("保留这个想法", seconds: 2)
    let short = record("海", seconds: 3)
    let different = record("保留这个想法！", seconds: 4)
    let voice = record("", seconds: 5, media: true)
    let conversation = record("保留这个想法", seconds: 6, conversation: true)
    let records = [duplicate, short, original, different, voice, conversation]
    #expect(PointOrganization.cleanupCandidates(records).map(\.id) == [duplicate.id])
    #expect(PointOrganization.cleanupCandidates(records.reversed()).map(\.id) == [duplicate.id])
    #expect(PointOrganization.cleanupCandidates([record("", seconds: 7)]).count == 1)
}

@Test func trashIsReversibleAndHiddenFromSearchMapsEmbeddingsAndRecall() async throws {
    let db = try PointDatabase(inMemory: true)
    try await db.migrate()
    let id = try await db.commitTextPoint(text: "Swift 数据库恢复实验", createdAt: Date(timeIntervalSince1970: 1))
    try await db.saveFacetOverride(pointID: id, dimension: .project, values: ["保留的项目"])
    let record = try #require(try await db.organizationRecords().first)
    try await db.saveEmbedding(.init(pointID: id, revision: record.revision, modelID: "test", vector: [1, 0]))
    try await db.saveGeographies([.init(pointID: id, geographyVersion: "test", contentRevision: record.revision,
        communityID: "keep", latitude: 10, longitude: 20, altitude: 0, placementConfidence: 1, isPinned: true)])
    #expect(try await db.moveToTrash([.init(pointID: id, reason: "测试可恢复", expectedRevision: record.revision)]) == 1)
    #expect(try await db.listPoints(matching: "").isEmpty)
    for query in ["Swift", "数据库", "恢复", "%", "_"] { #expect(try await db.listPoints(matching: query).isEmpty) }
    #expect(try await db.pointMapEntries().isEmpty)
    #expect(try await db.organizationRecords().isEmpty)
    #expect(try await db.embeddings(modelID: "test").isEmpty)
    #expect(try await db.geographies(version: "test").isEmpty)
    #expect(try await db.queuedEmbeddingDocuments(modelID: "missing-model").isEmpty)
    #expect(try await db.rediscoveryItems(referenceDate: Date(), limit: 5).isEmpty)
    #expect(try await db.pointDetail(id: id).sourceText == "Swift 数据库恢复实验")
    #expect(try await db.facetOverrides().first?.values == ["保留的项目"])
    #expect(try await db.trashedPoints().first?.reason == "测试可恢复")
    #expect(try await db.moveToTrash([.init(pointID: id, reason: "不覆盖首次原因")]) == 0)
    #expect(try await db.restoreFromTrash([id]) == 1)
    #expect(try await db.restoreFromTrash([id]) == 0)
    #expect(try await db.listPoints(matching: "Swift").count == 1)
    #expect(try await db.pointMapEntries().first?.content == "Swift 数据库恢复实验")
    #expect(try await db.embeddings(modelID: "test").count == 1)
    #expect(try await db.geographies(version: "test").first?.isPinned == true)
    #expect(try await db.trashedPoints().isEmpty)
}

@Test func trashRetainsUntranscribedAudioAndImagesAndKeepsDatabasesIsolated() async throws {
    let test = try PointDatabase(inMemory: true), production = try PointDatabase(inMemory: true)
    try await test.migrate(); try await production.migrate()
    let real = try await production.commitTextPoint(text: "正式用户内容")
    let audio = StoredAudio(assetID: UUID(), relativePath: "blobs/audio/keep.m4a", sha256: "abc", byteCount: 3, durationMilliseconds: 1000)
    let id = try await test.commitVoiceCapture(.init(operationID: UUID(), audio: audio))
    try await test.addImage(pointID: id, id: UUID(), relativePath: "photos/keep.jpg", sha256: "image", byteCount: 10, recognizedText: "important OCR")
    #expect(try await test.organizationRecords().first?.hasMedia == true)
    #expect(PointOrganization.cleanupCandidates(try await test.organizationRecords()).isEmpty)
    try await test.moveToTrash([.init(pointID: id, reason: "用户确认")])
    #expect(try await test.queuedTranscriptionPointIDs().isEmpty)
    #expect(try await test.listPoints(matching: "important OCR").isEmpty)
    #expect(try await test.images(pointID: id).first?.relativePath == "photos/keep.jpg")
    #expect(try await test.pointDetail(id: id).audioRelativePath == audio.relativePath)
    #expect(try await production.listPoints(matching: "").map(\.id) == [real])
    #expect(try await production.trashedPoints().isEmpty)
    try await test.restoreFromTrash([id])
    #expect(try await test.queuedTranscriptionPointIDs() == [id])
    #expect(try await test.listPoints(matching: "important OCR").count == 1)
}

@Test func cleanupAndReorganizationSkipContentChangedAfterPreview() async throws {
    let db = try PointDatabase(inMemory: true)
    try await db.migrate()
    let id = try await db.commitTextPoint(text: "需要保留的新内容")
    let record = try #require(try await db.organizationRecords().first)
    let review = LCCClassificationReview(entry: record.entry, embeddingModelID: "test", judgeModelID: "test",
        candidates: [], decision: .init(status: .themeOnly, ids: [], reason: "主题"), theme: "学习", rawTheme: "学习", mappingVersion: PointThemeClassifier.mappingVersion)
    try await db.appendConversationMessage(pointID: id, role: "user", text: "这条不是垃圾，有重要补充")
    #expect(try await db.moveToTrash([.init(pointID: id, reason: "旧预览", expectedRevision: record.revision)]) == 0)
    #expect(try await db.saveLCCClassificationReview(review, expectedRevision: record.revision) == false)
    #expect(try await db.listPoints(matching: "").count == 1)
    #expect(try await db.lccClassificationReviews().isEmpty)
    #expect(try await db.organizationRecords().first?.hasConversation == true)
}
