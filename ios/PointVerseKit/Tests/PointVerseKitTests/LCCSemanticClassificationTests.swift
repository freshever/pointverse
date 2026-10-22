import Foundation
import Testing
@testable import PointVerseKit

private func lccEntry(_ text: String, id: PointID = PointID()) -> PointMapEntry {
    .init(point: .init(id: id, title: "", createdAt: Date(), transcriptState: nil), content: text, localeIdentifier: "zh-CN")
}

@Test func lccRecallValidatesVectorsAndDoesNotTurnRankIntoAssignments() {
    let hits = LCCSemanticClassification.rank(query: [1, 0], vectors: [
        "lcc:QA": [1, 0], "lcc:QB": [0, 1], "invented": [1, 0], "lcc:QC": [.nan, 0],
        "lcc:QD": [0, 0], "lcc:QE": [1]
    ])
    #expect(hits.map(\.id) == ["lcc:QA", "lcc:QB"])
    #expect(hits.first?.cosine == 1)
    #expect(LCCSemanticClassification.rank(query: [.infinity, 0], vectors: ["lcc:QA": [1, 0]]).isEmpty)
    #expect(LCCSemanticClassification.rank(query: [1, 0], vectors: ["lcc:QA": [1, 0]], limit: 0).isEmpty)
}

@Test func lccJudgeRejectsInventedIDsConflictingStatesAndRedundantAncestors() throws {
    let allowed: Set<String> = ["lcc:Q", "lcc:QA"]
    let good = try LCCClassificationDecision.parse("```json\n{\"status\":\"suggested\",\"ids\":[\"lcc:QA\"],\"reason\":\"内容明确讨论数学\"}\n```", allowed: allowed)
    #expect(good.ids == ["lcc:QA"])
    let uncertain = try LCCClassificationDecision.parse("{\"status\":\"uncertain\",\"ids\":[],\"reason\":\"信息不足\"}", allowed: allowed)
    #expect(uncertain.ids.isEmpty)
    for raw in [
        "{\"status\":\"suggested\",\"ids\":[\"lcc:FAKE\"],\"reason\":\"理由\"}",
        "{\"status\":\"suggested\",\"ids\":[\"lcc:QB\"],\"reason\":\"非候选\"}",
        "{\"status\":\"suggested\",\"ids\":[],\"reason\":\"理由\"}",
        "{\"status\":\"uncertain\",\"ids\":[\"lcc:QA\"],\"reason\":\"理由\"}",
        "{\"status\":\"suggested\",\"ids\":[\"lcc:Q\",\"lcc:QA\"],\"reason\":\"理由\"}",
        "{\"status\":\"suggested\",\"ids\":[\"lcc:QA\",\"lcc:QA\"],\"reason\":\"理由\"}",
        "{\"status\":\"candidateGap\",\"ids\":[],\"reason\":\" \"}",
        "我认为数学比较适合"
    ] {
        do { _ = try LCCClassificationDecision.parse(raw, allowed: allowed); Issue.record("Accepted invalid judge output: \(raw)") }
        catch { }
    }
}

@Test func lccReviewsPersistWithoutOverridingManualMembershipAndInvalidateOnEdits() async throws {
    let database = try PointDatabase(inMemory: true), other = try PointDatabase(inMemory: true)
    try await database.migrate(); try await other.migrate()
    let id = try await database.commitTextPoint(text: "思考复杂度的增长")
    let entry = lccEntry("思考复杂度的增长", id: id)
    try await database.saveFacetOverride(pointID: id, dimension: .domain, values: [])
    let review = LCCClassificationReview(entry: entry, embeddingModelID: "stub-e5", judgeModelID: "actual-model",
        candidates: [.init(id: "lcc:QA", cosine: 0.86)],
        decision: .init(status: .suggested, ids: ["lcc:QA"], reason: "讨论数学复杂度"))
    try await database.saveLCCClassificationReview(review)
    let saved = try #require(try await database.lccClassificationReviews().first)
    #expect(saved == review)
    #expect(saved.isCurrent(for: entry))
    #expect(!saved.isCurrent(for: lccEntry("换了主题", id: id)))
    #expect(!saved.isCurrent(for: lccEntry(entry.content)))
    #expect(saved.embeddingModelID == "stub-e5" && saved.judgeModelID == "actual-model")
    #expect(try await other.lccClassificationReviews().isEmpty)
    #expect(try await database.facetOverrides().first?.values == [])
    let classification = PointFacetEngine.classify(entry, overrides: try await database.facetOverrides())
    #expect(classification.values[.domain]?.isEmpty == true)
    try await database.saveLCCClassificationReview(review)
    #expect(try await database.lccClassificationReviews().count == 1)
    _ = try await database.deletePoint(id: id)
    #expect(try await database.lccClassificationReviews().isEmpty)
}

@Test func lccDescriptorsKeepTargetFirstAndExplainAppAuthoredHints() throws {
    let term = try #require(LCCCatalog.byID["lcc:QA76.75-76.765"])
    let text = LCCSemanticClassification.descriptor(term)
    #expect(text.hasPrefix(term.displayTitle))
    #expect(text.contains("Computer software"))
    #expect(text.contains("点界检索示例"))
    let input = LCCSemanticClassification.judgeInput(entry: lccEntry(String(repeating: "字", count: 1000)),
        candidates: [.init(id: term.id, cosine: 0.9)])
    #expect(input.contains(term.id))
    #expect(!input.contains(String(repeating: "字", count: 601)))
}

@Test func friendlyClassificationNamesDoNotChangeOfficialCatalogOrAssignments() throws {
    let software = try #require(LCCCatalog.byID["lcc:QA76.75-76.765"])
    #expect(software.friendlyTitle == "软件开发")
    #expect(software.englishTitle == "Computer software")
    #expect(software.displayTitle.hasPrefix("QA76.75-76.765 · "))
    #expect(LCCCatalog.friendlyTitle("lcc:BF") == "心理与情绪")
    #expect(LCCCatalog.friendlyTitle("lcc:TX") == "居家生活与烹饪")
    #expect(LCCCatalog.friendlyTitle("software").contains("旧自定义"))
    for term in LCCCatalog.snapshot?.terms ?? [] { #expect(!term.friendlyTitle.isEmpty) }
    let entry = lccEntry("我在学习写作和绘画")
    let manual = PointFacetEngine.classify(entry, overrides: [.init(pointID: entry.id, dimension: .domain, values: ["lcc:PN", "lcc:ND", "lcc:LB"])])
    #expect(manual.values[.domain]?.count == 3)
    #expect(manual.values[.domain] == ["lcc:PN", "lcc:ND", "lcc:LB"])
    do {
        _ = try LCCClassificationDecision.parse("{\"status\":\"suggested\",\"ids\":[\"lcc:PN\",\"lcc:ND\",\"lcc:LB\"],\"reason\":\"跨三个领域\"}", allowed: ["lcc:PN", "lcc:ND", "lcc:LB"])
        Issue.record("Model returned more than two recommendations")
    } catch { }
}

@Test func classificationReviewShowsOnlyPrimaryRecommendationAndDoesNotPromoteUncertainty() {
    let entry = lccEntry("学习和写作")
    let candidates: [LCCSemanticCandidate] = [.init(id: "lcc:PN", cosine: 0.9), .init(id: "lcc:LB", cosine: 0.88)]
    for (status, expected) in [(LCCClassificationDecision.Status.suggested, "lcc:LB"), (.retrievalOnly, "lcc:PN"), (.uncertain, nil), (.candidateGap, nil)] {
        let review = LCCClassificationReview(entry: entry, embeddingModelID: "stub", judgeModelID: nil,
            candidates: candidates, decision: .init(status: status, ids: status == .suggested ? ["lcc:LB", "lcc:PN"] : [], reason: "理由"))
        #expect(review.primaryRecommendationID == expected)
        #expect(review.candidates.count == 2)
    }
}
