import Foundation
import Testing
@testable import PointVerseKit

@Test func semanticCitiesKeepIdenticalContentAndSmallParentsTogether() {
    let ids = (0..<20).map { _ in PointID() }
    let records = ids.map { PointEmbeddingRecord(pointID: $0, revision: 1, modelID: "m", vector: [1, 0, 0]) }
    #expect(SemanticSubtopicEngine.partition(memberIDs: ids, embeddings: records).count == 1)
    #expect(SemanticSubtopicEngine.partition(memberIDs: Array(ids.prefix(3)), embeddings: records).count == 1)
    #expect(SemanticSubtopicEngine.partition(memberIDs: ids, embeddings: []).count == 1)
}

@Test func semanticCitiesSeparateThemesAndPreserveEveryPointExactlyOnce() {
    let ids = (0..<12).map { _ in PointID() }
    let records = ids.enumerated().map { i, id in
        PointEmbeddingRecord(pointID: id, revision: 1, modelID: "m", vector: i < 6 ? [1, 0, 0.1] : [0, 1, 0.1])
    }
    let groups = SemanticSubtopicEngine.partition(memberIDs: ids, embeddings: records)
    #expect(groups.count == 2)
    #expect(Set(groups.flatMap { $0 }) == Set(ids))
    #expect(groups.flatMap { $0 }.count == ids.count)
    #expect(groups.contains { Set($0) == Set(ids.prefix(6)) })
    #expect(groups == SemanticSubtopicEngine.partition(memberIDs: ids.reversed(), embeddings: records.reversed()))
    #expect(SemanticSubtopicEngine.partition(memberIDs: ids, embeddings: Array(records.dropLast())).count == 1)
}

@Test func semanticCommunityUnitsNeverSplitAnExistingProvince() {
    let ids = (0..<6).map { _ in PointID() }
    let geographies = ids.prefix(4).enumerated().map { i, id in
        PointGeographyRecord(pointID: id, geographyVersion: GeographyIdentity.relativeSemanticV6,
                             contentRevision: 1, communityID: i < 2 ? "a" : "b", latitude: Double(i), longitude: 0,
                             placementConfidence: 1)
    }
    let units = SemanticSubtopicEngine.communityUnits(memberIDs: ids, geographies: geographies)
    #expect(units.count == 4)
    #expect(units.contains { Set($0) == Set(ids.prefix(2)) })
    #expect(units.contains { Set($0) == Set(ids[2..<4]) })
    #expect(units.flatMap { $0 }.count == ids.count)
    #expect(Set(units.flatMap { $0 }) == Set(ids))
}
