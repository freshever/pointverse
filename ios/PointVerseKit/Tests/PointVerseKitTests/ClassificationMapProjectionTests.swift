import Foundation
import Testing
@testable import PointVerseKit

private func mapEntry(_ text: String) -> PointMapEntry {
    .init(point: .init(id: PointID(), title: "", createdAt: Date(), transcriptState: nil), content: text, localeIdentifier: "zh-CN")
}
private func mappedReview(_ entry: PointMapEntry, _ raw: String) throws -> LCCClassificationReview {
    let value = try PointThemeClassifier.parse(raw)
    return .init(entry: entry, embeddingModelID: "unused", judgeModelID: "test", candidates: [],
        decision: .init(status: value.domainID == nil ? .themeOnly : .suggested, ids: value.domainID.map { [$0] } ?? [], reason: "程序匹配"),
        theme: value.theme, rawTheme: raw, mappingVersion: PointThemeClassifier.mappingVersion)
}

@Test func modelThemeMappingAppliesDomainImmediatelyWithoutCreatingManualOverrides() throws {
    let entry = mapEntry("这一杯研磨得细一点")
    let review = try mappedReview(entry, "咖啡制作")
    let result = PointFacetEngine.classify(entry, review: review)
    #expect(result.values[.domain] == ["lcc:TX"])
    #expect(result.modelDimensions == [.domain, .topic])
    #expect(result.manualDimensions.isEmpty)
    let rejected = PointFacetEngine.classify(entry, overrides: [.init(pointID: entry.id, dimension: .domain, values: [])], review: review)
    #expect(rejected.values[.domain]?.isEmpty == true)
    #expect(!rejected.modelDimensions.contains(.domain))
    let changed = PointMapEntry(point: entry.point, content: "内容发生变化", localeIdentifier: "zh-CN")
    #expect(PointFacetEngine.classify(changed, review: review).values[.domain]?.isEmpty == true)
}

@Test func mapProjectionGroupsEquivalentThemesAndSeparatesDifferentDomainsDeterministically() throws {
    let coffee = mapEntry("第一杯"), bread = mapEntry("第二餐"), sky = mapEntry("望着星空")
    let entries = [coffee, bread, sky]
    let reviews = try [mappedReview(coffee, "咖啡制作"), mappedReview(bread, "烘焙"), mappedReview(sky, "天文")]
    let projected = ClassificationMapProjection.make(entries: entries, geographies: [], overrides: [], reviews: reviews)
    #expect(projected.count == 3)
    let a = try #require(ClassificationMapProjection.region(projected[0].communityID))
    let b = try #require(ClassificationMapProjection.region(projected[1].communityID))
    let c = try #require(ClassificationMapProjection.region(projected[2].communityID))
    #expect(a.planetID == b.planetID)
    #expect(a.provinceName == "居家生活与烹饪" && a.topicName == "烹饪")
    #expect(a.rootID == "direction:living" && a.planetID == "direction:life")
    #expect(c.rootID == "direction:exploration" && c.planetID == "direction:science")
    #expect(projected == ClassificationMapProjection.make(entries: entries, geographies: [], overrides: [], reviews: reviews))
    #expect(projected[0].longitude != projected[1].longitude || projected[0].latitude != projected[1].latitude)
    #expect(ClassificationMapProjection.region("old-community") == nil)
}

@Test func unknownThemeGetsExplorationPlanetAndManualDomainTakesPriority() throws {
    let entry = mapEntry("城市慢慢苏醒")
    let review = try mappedReview(entry, "城市呼吸")
    let unknown = ClassificationMapProjection.make(entries: [entry], geographies: [], overrides: [], reviews: [review])
    let region = try #require(ClassificationMapProjection.region(unknown[0].communityID))
    #expect(region.planetName == "待整理" && region.provinceName == "未匹配目录" && region.topicName == "城市呼吸")
    let manual = ClassificationMapProjection.make(entries: [entry], geographies: [],
        overrides: [.init(pointID: entry.id, dimension: .domain, values: ["lcc:PN"])], reviews: [review])
    #expect(ClassificationMapProjection.region(manual[0].communityID)?.planetID == "direction:creation")
    #expect(ClassificationMapProjection.region(manual[0].communityID)?.provinceID == "lcc:PN")
}

@Test func projectionPreservesStoredCoordinatesPinsAndOriginalRecords() throws {
    let entry = mapEntry("短句")
    let old = PointGeographyRecord(pointID: entry.id, geographyVersion: "original", contentRevision: 3,
        communityID: "original-community", latitude: 23, longitude: 46, altitude: 1.2, placementConfidence: 0.8, isPinned: true)
    #expect(ClassificationMapProjection.make(entries: [entry], geographies: [old], overrides: [], reviews: []) == [old])
    let review = try mappedReview(entry, "园艺")
    let projected = ClassificationMapProjection.make(entries: [entry], geographies: [old], overrides: [], reviews: [review])
    #expect(projected[0].latitude == old.latitude && projected[0].longitude == old.longitude)
    #expect(projected[0].isPinned)
    #expect(old.communityID == "original-community" && old.geographyVersion == "original")
}

@Test func automaticClassificationPersistsAsAutomaticAndManualEditsRemainSeparate() async throws {
    let db = try PointDatabase(inMemory: true)
    try await db.migrate()
    let id = try await db.commitTextPoint(text: "今天练习")
    let entry = PointMapEntry(point: .init(id: id, title: "", createdAt: Date(), transcriptState: nil), content: "今天练习", localeIdentifier: "zh-CN")
    try await db.saveLCCClassificationReview(mappedReview(entry, "运动"))
    let review = try #require(try await db.lccClassificationReviews().first)
    #expect(PointFacetEngine.classify(entry, review: review).values[.domain] == ["lcc:GV"])
    #expect(try await db.facetOverrides().isEmpty)
    try await db.saveFacetOverride(pointID: id, dimension: .domain, values: ["lcc:R"])
    #expect(PointFacetEngine.classify(entry, overrides: try await db.facetOverrides(), review: review).values[.domain] == ["lcc:R"])
}

@Test func allCatalogClassesFitWithinSevenStablePlanetDirections() throws {
    let terms = try #require(LCCCatalog.snapshot?.terms)
    let entries = terms.map { _ in mapEntry("内容样本") }
    let manual = zip(entries, terms).map { PointFacetOverride(pointID: $0.0.id, dimension: .domain, values: [$0.1.id]) }
    let projected = ClassificationMapProjection.make(entries: entries, geographies: [], overrides: manual, reviews: [])
    let regions = projected.compactMap { ClassificationMapProjection.region($0.communityID) }
    #expect(regions.count == terms.count)
    #expect(Set(regions.map(\.planetID)).count <= 7)
    #expect(ClassificationMapProjection.PlanetDirection.allCases.count == 7)
    #expect(Set(regions.compactMap(\.provinceID)) == Set(terms.map(\.id)))
    for (domain, expected) in [("lcc:QA76.75-76.765", "技术与工具"), ("lcc:QA75.5-76.95", "技术与工具"),
        ("lcc:ZA", "技术与工具"), ("lcc:QB", "科学探索"), ("lcc:QC", "科学探索"),
        ("lcc:TX", "日常生活"), ("lcc:SB", "日常生活"), ("lcc:GV", "身心与关系"),
        ("lcc:BF", "身心与关系"), ("lcc:HG", "社会与世界"), ("lcc:PN", "创作与表达"), ("lcc:TR", "创作与表达")] {
        #expect(ClassificationMapProjection.direction(for: domain).title == expected)
    }
}

@Test func differentTopicsStayInOneProvinceAndDoNotCreateAdditionalPlanets() throws {
    let a = mapEntry("第一项"), b = mapEntry("第二项")
    let manual: [PointFacetOverride] = [
        .init(pointID: a.id, dimension: .domain, values: ["lcc:QA76.75-76.765"]),
        .init(pointID: b.id, dimension: .domain, values: ["lcc:QA76.75-76.765"]),
        .init(pointID: a.id, dimension: .topic, values: ["memory-management"]),
        .init(pointID: b.id, dimension: .topic, values: ["concurrency"])
    ]
    let projection = ClassificationMapProjection.make(entries: [a,b], geographies: [], overrides: manual, reviews: [])
    let first = try #require(ClassificationMapProjection.region(projection[0].communityID))
    let second = try #require(ClassificationMapProjection.region(projection[1].communityID))
    #expect(first.planetID == second.planetID)
    #expect(first.provinceCommunityID == second.provinceCommunityID)
    #expect(first.provinceName == "软件开发")
    #expect(first.topicName == "内存管理" && second.topicName == "并发与同步")
    let reordered = ClassificationMapProjection.make(entries: [b,a], geographies: [], overrides: Array(manual.reversed()), reviews: [])
    #expect(Dictionary(uniqueKeysWithValues: projection.map { ($0.pointID, $0.communityID) })
        == Dictionary(uniqueKeysWithValues: reordered.map { ($0.pointID, $0.communityID) }))
}
