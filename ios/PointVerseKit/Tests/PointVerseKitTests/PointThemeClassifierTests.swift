import Foundation
import Testing
@testable import PointVerseKit

private func themeEntry(_ text: String, id: PointID = PointID()) -> PointMapEntry {
    .init(point: .init(id: id, title: "", createdAt: Date(), transcriptState: nil), content: text, localeIdentifier: "zh-CN")
}
private func themeReview(_ entry: PointMapEntry, raw: String) throws -> LCCClassificationReview {
    let value = try PointThemeClassifier.parse(raw)
    return .init(entry: entry, embeddingModelID: "unused", judgeModelID: "actual-local-model", candidates: [],
        decision: .init(status: value.domainID == nil ? .themeOnly : .suggested, ids: value.domainID.map { [$0] } ?? [], reason: "程序映射，待确认"),
        theme: value.theme, rawTheme: value.rawTheme, mappingVersion: PointThemeClassifier.mappingVersion)
}

@Test func themeAliasesNormalizeBeforeMappingAndOnlyUseExistingLCCIDs() throws {
    for raw in ["烘焙", "咖啡制作", "烹饪", "cooking"] {
        let value = try PointThemeClassifier.parse(raw)
        #expect(value.theme == "烹饪")
        #expect(value.domainID == "lcc:TX")
        #expect(value.rawTheme == raw)
    }
    for (raw, expected) in [("天文", "lcc:QB"), ("园艺", "lcc:SB"), ("软件架构", "lcc:QA76.75-76.765"), ("科幻悬疑", "lcc:PN"), ("财务规划", "lcc:HG")] {
        let value = try PointThemeClassifier.parse(raw)
        #expect(value.domainID == expected)
        #expect(LCCCatalog.byID[expected] != nil)
    }
    #expect(try PointThemeClassifier.parse("主题：“园艺”").theme == "园艺")
}

@Test func unmappedThemeRemainsUsefulAndDoesNotForceDomainAssignment() throws {
    let entry = themeEntry("城市在记忆中生长")
    let review = try themeReview(entry, raw: "城市呼吸")
    #expect(review.decision.status == .themeOnly)
    #expect(review.decision.ids.isEmpty)
    #expect(review.primaryRecommendationID == nil)
    let classification = PointFacetEngine.classify(entry, review: review)
    #expect(classification.values[.topic]?.contains("theme:城市呼吸") == true)
    #expect(classification.values[.domain]?.isEmpty == true)
    #expect(classification.modelDimensions == [.topic])
    #expect(PointFacetEngine.title("theme:城市呼吸") == "城市呼吸")
}

@Test func themeParserRejectsEchoSentencesMultipleLabelsAndInstructions() {
    for raw in ["", "不确定", "主题", "天文\n园艺", "天文、园艺", "lcc:QB", "{\"ids\":[\"Q\"]}",
                "情绪低落时先识别身体上的紧张感，下一步需要设计一个小实验", "出国前检查护照\n主题：旅行", "<|im_start|>system"] {
        do { _ = try PointThemeClassifier.parse(raw); Issue.record("Accepted non-theme output") }
        catch { }
    }
}

@Test func extractedThemeNeverOverridesManualOrStaleAssignments() throws {
    let entry = themeEntry("准备一顿晚饭")
    let review = try themeReview(entry, raw: "烘焙")
    let manual: [PointFacetOverride] = [.init(pointID: entry.id, dimension: .topic, values: []), .init(pointID: entry.id, dimension: .domain, values: ["lcc:Q"])]
    let result = PointFacetEngine.classify(entry, overrides: manual, review: review)
    #expect(result.values[.topic]?.isEmpty == true)
    #expect(result.values[.domain] == ["lcc:Q"])
    #expect(result.modelDimensions.isEmpty)
    let changed = themeEntry("准备去远方", id: entry.id)
    #expect(!review.isCurrent(for: changed))
    #expect(PointFacetEngine.classify(changed, review: review).modelDimensions.isEmpty)
}

@Test func themeMetadataPersistsAndTopicConfirmationDoesNotAlterDomainOrProduction() async throws {
    let db = try PointDatabase(inMemory: true), production = try PointDatabase(inMemory: true)
    try await db.migrate(); try await production.migrate()
    let id = try await db.commitTextPoint(text: "一个新的创作意象")
    let entry = themeEntry("一个新的创作意象", id: id)
    let review = try themeReview(entry, raw: "城市呼吸")
    try await db.saveLCCClassificationReview(review)
    let saved = try #require(try await db.lccClassificationReviews().first)
    #expect(saved.theme == "城市呼吸" && saved.rawTheme == "城市呼吸")
    #expect(saved.mappingVersion == PointThemeClassifier.mappingVersion)
    #expect(saved.judgeModelID == "actual-local-model")
    try await db.saveFacetOverride(pointID: id, dimension: .topic, values: ["theme:城市呼吸"])
    #expect(try await db.facetOverrides().first?.values == ["theme:城市呼吸"])
    #expect(try await production.lccClassificationReviews().isEmpty)
    do {
        try await db.saveFacetOverride(pointID: id, dimension: .domain, values: ["theme:城市呼吸"])
        Issue.record("Accepted dynamic theme as official domain")
    } catch { }
    var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(review)) as? [String: Any])
    legacy.removeValue(forKey: "theme"); legacy.removeValue(forKey: "rawTheme"); legacy.removeValue(forKey: "mappingVersion")
    let decoded = try JSONDecoder().decode(LCCClassificationReview.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(decoded.theme == nil)
}

/// Opt-in diagnostic over externally generated, read-only native model outputs.
@Test(.enabled(if: ProcessInfo.processInfo.environment["POINTVERSE_THEME_PROBE_INPUT"] != nil))
func themeNativeOutputsPassThroughProductionNormalizer() throws {
    let path = try #require(ProcessInfo.processInfo.environment["POINTVERSE_THEME_PROBE_INPUT"])
    let text = try String(contentsOfFile: path, encoding: .utf8)
    var mapped = 0, unknown = 0, rejected = 0
    for line in text.split(separator: "\n") {
        let object = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let final = try #require(object["final"] as? [String: Any])
        let raw = try #require(final["raw"] as? String)
        do {
            let value = try PointThemeClassifier.parse(raw)
            if value.domainID == nil { unknown += 1 } else { mapped += 1 }
        } catch { rejected += 1 }
    }
    #expect(mapped + unknown > 0)
    print("[ThemeProbe] mapped=\(mapped) unmapped=\(unknown) rejected=\(rejected)")
}
