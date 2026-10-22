import Foundation
import Testing
@testable import PointVerseKit

@Test func provinceQualitySeparatesCohesionAndOutsideSimilarity() {
    let a = PointID(), b = PointID(), c = PointID()
    let model = "test"
    let vectors = [
        PointEmbeddingRecord(pointID: a, revision: 1, modelID: model, vector: [1, 0]),
        PointEmbeddingRecord(pointID: b, revision: 1, modelID: model, vector: [2, 0]),
        PointEmbeddingRecord(pointID: c, revision: 1, modelID: model, vector: [0, 1])
    ]
    let metrics = ProvinceQualityMetrics.compute(memberIDs: [a, b], embeddings: vectors, modelID: model)
    #expect(metrics.median == 1)
    #expect(metrics.outsideMedian == 0)
    #expect(metrics.pairCount == 1)
    #expect(metrics.suspiciousIDs.isEmpty)
    #expect(metrics.weakestPairs.first?.similarity == 1)
    let singleton = ProvinceQualityMetrics.compute(memberIDs: [a], embeddings: vectors, modelID: model)
    #expect(singleton.median == nil)
    #expect(singleton.suspiciousIDs.isEmpty)
}

@Test func provinceQualityRejectsInvalidVectorsAndIsOrderIndependent() {
    let ids = (0..<140).map { _ in PointID() }
    var vectors = ids.map { PointEmbeddingRecord(pointID: $0, revision: 1, modelID: "m", vector: [1, 2]) }
    vectors.append(.init(pointID: PointID(), revision: 1, modelID: "m", vector: [0, 0]))
    vectors.append(.init(pointID: PointID(), revision: 1, modelID: "m", vector: [.nan, 1]))
    vectors.append(.init(pointID: PointID(), revision: 1, modelID: "other", vector: [1, 2]))
    vectors.append(.init(pointID: PointID(), revision: 1, modelID: "m", vector: [1]))
    let first = ProvinceQualityMetrics.compute(memberIDs: Set(ids), embeddings: vectors, modelID: "m")
    let second = ProvinceQualityMetrics.compute(memberIDs: Set(ids), embeddings: vectors.reversed(), modelID: "m")
    #expect(first.validMembers == 140)
    #expect(first.sampledMembers == 128)
    #expect(first.sampledOutsiders == 0)
    #expect(first.pairCount == 8128)
    #expect(first.median == second.median)
}

@Test func provinceQualityFlagsCrossProvinceAffinityWithoutTreatingItAsMembership() {
    let a = PointID(), b = PointID(), outside = PointID()
    let records = [
        PointEmbeddingRecord(pointID: a, revision: 1, modelID: "m", vector: [1, 0]),
        PointEmbeddingRecord(pointID: b, revision: 1, modelID: "m", vector: [-1, 0]),
        PointEmbeddingRecord(pointID: outside, revision: 1, modelID: "m", vector: [1, 0])
    ]
    let result = ProvinceQualityMetrics.compute(memberIDs: [a, b], embeddings: records, modelID: "m")
    #expect(result.median == -1)
    #expect(result.outsideMedian == 0)
    #expect(result.suspiciousIDs == [a])
    #expect(result.weakestPairs.first?.similarity == -1)
    #expect(result.validMembers == 2)
}

@Test func provinceEvaluationSnapshotsPersistWithoutChangingPointsAndAreIsolated() async throws {
    let database = try PointDatabase(inMemory: true)
    let other = try PointDatabase(inMemory: true)
    try await database.migrate()
    try await other.migrate()
    let id = try await database.commitTextPoint(text: "原始想法")
    var record = ProvinceEvaluation(provinceID: "p", provinceName: "技术省", members: [.init(id: id, revision: 1, text: "原始想法")])
    record.verdict = "明显混杂"
    record.humanScore = 2
    record.pairAnnotations["pair"] = "基本无关"
    record.annotations[id.rawValue.uuidString] = "应该移走"
    record.aiReports = ["仅建议改名"]
    record.aiModels = ["actual-model"]
    record.decision = "接受建议（仅记录）"
    try await database.saveProvinceEvaluation(record)
    let saved = try #require(try await database.provinceEvaluations(provinceID: "p").first)
    #expect(saved.members.first?.text == "原始想法")
    #expect(saved.annotations[id.rawValue.uuidString] == "应该移走")
    #expect(saved.aiModels == ["actual-model"])
    #expect(saved.humanScore == 2)
    #expect(saved.pairAnnotations["pair"] == "基本无关")
    #expect(try await other.provinceEvaluations(provinceID: "p").isEmpty)
    #expect(try await database.listPoints(matching: "").count == 1)
    #expect(try await database.provinceEvaluations(provinceID: "different").isEmpty)
    #expect(try await database.evaluatedScopeIDs() == ["p"])
}

@Test func hierarchicalEvaluationPreservesScopeAndDecodesLegacySnapshots() throws {
    let record = ProvinceEvaluation(provinceID: "planet-a/city-b", provinceName: "模型市", members: [],
                                   scopeLevel: "市", hierarchyPath: ["技术恒星系", "AI行星", "工具省", "模型市"])
    let data = try JSONEncoder().encode(record)
    let decoded = try JSONDecoder().decode(ProvinceEvaluation.self, from: data)
    #expect(decoded.scopeLevel == "市")
    #expect(decoded.hierarchyPath?.count == 4)
    var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    legacy.removeValue(forKey: "scopeLevel")
    legacy.removeValue(forKey: "hierarchyPath")
    let old = try JSONDecoder().decode(ProvinceEvaluation.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(old.scopeLevel == nil)
    #expect(old.hierarchyPath == nil)
}
