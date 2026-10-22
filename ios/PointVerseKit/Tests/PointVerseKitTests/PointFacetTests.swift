import Foundation
import Testing
@testable import PointVerseKit

private func facetEntry(_ text: String, id: PointID = PointID()) -> PointMapEntry {
    .init(point: .init(id: id, title: "", createdAt: Date(), transcriptState: nil), content: text, localeIdentifier: "zh-CN")
}

@Test func facetsClassifyIndependentDimensionsWithoutInventingProjects() {
    let entry = facetEntry("做点界项目时我发现 Swift 内存循环引用问题，能不能换个方法？")
    let result = PointFacetEngine.classify(entry)
    #expect(result.values[.domain]?.contains("lcc:QA76.75-76.765") == true)
    #expect(result.values[.topic]?.contains("memory-management") == true)
    #expect(result.values[.expression]?.contains("question") == true)
    #expect(result.values[.expression]?.contains("hypothesis") == true)
    #expect(result.values[.expression]?.contains("experience") == true)
    #expect(result.values[.project]?.isEmpty != false)
    #expect(PointFacetEngine.belongs("lcc:QA76.75-76.765", to: "lcc:Q"))
    #expect(result.values[.domain]?.contains("technology") != true)
}

@Test func facetFiltersUseOrWithinAndAcrossDimensions() {
    let entry = facetEntry("如何修复 Swift 内存循环引用？")
    let result = PointFacetEngine.classify(entry, overrides: [.init(pointID: entry.id, dimension: .project, values: ["点界"])])
    #expect(PointFacetEngine.matches(result, filters: [.domain: ["lcc:Q"], .project: ["点界"], .expression: ["question", "plan"]]))
    #expect(!PointFacetEngine.matches(result, filters: [.project: ["装修"]]))
    #expect(!PointFacetEngine.matches(result, filters: [.project: ["点界"], .expression: ["plan"]]))
    #expect(PointFacetEngine.matches(result, filters: [:]))
}

@Test func facetManualEmptySuppressesSuggestionsAndOtherDimensionsSurvive() {
    let entry = facetEntry("Swift 内存管理怎么办？")
    let result = PointFacetEngine.classify(entry, overrides: [.init(pointID: entry.id, dimension: .topic, values: [])])
    #expect(result.values[.topic]?.isEmpty == true)
    #expect(result.manualDimensions == [.topic])
    #expect(result.values[.domain]?.contains("lcc:QA76.75-76.765") == true)
    #expect(PointFacetEngine.matches(result, filters: [.topic: [PointFacetEngine.unassigned]]))
    #expect(!PointFacetEngine.matches(result, filters: [.topic: ["memory-management"]]))
    let unknown = PointFacetEngine.classify(facetEntry("嗯"))
    #expect(unknown.values.values.allSatisfy { $0.isEmpty })
    #expect(PointFacetEngine.classify(facetEntry("The partial result remains available")).values[.domain]?.contains("ai") != true)
}

@Test func lccOfficialSnapshotHasTraceableHierarchyAndPreservesLegacyOverrides() throws {
    let snapshot = try #require(LCCCatalog.snapshot)
    #expect(snapshot.terms.count == 217)
    #expect(snapshot.sources.count == 20)
    #expect(snapshot.sources.allSatisfy { $0.sha256.count == 64 && $0.pageCount > 0 })
    #expect(Set(snapshot.terms.filter { $0.parentID == nil }.map(\.code)) == Set("A B C D E F G H J K L M N P Q R S T U V Z".split(separator: " ").map(String.init)))
    for term in snapshot.terms {
        var seen = Set<String>()
        var current: String? = term.id
        while let id = current {
            let inserted = seen.insert(id).inserted
            #expect(inserted)
            if !inserted { break }
            current = LCCCatalog.byID[id]?.parentID
        }
    }
    #expect(LCCCatalog.byID["lcc:QA76.75-76.765"]?.parentID == "lcc:QA75.5-76.95")
    let entry = facetEntry("Swift 内存管理")
    let legacy = PointFacetEngine.classify(entry, overrides: [.init(pointID: entry.id, dimension: .domain, values: ["software"])])
    #expect(legacy.values[.domain] == ["software"])
    #expect(PointFacetEngine.belongs("software", to: "technology"))
    #expect(!PointFacetEngine.belongs("software", to: "lcc:Q"))
    #expect(PointFacetEngine.classify(entry).values[.domain]?.contains("software") != true)
}

@Test func facetOverridesPersistIndependentlyAndCascadeWithoutTouchingContent() async throws {
    let database = try PointDatabase(inMemory: true), other = try PointDatabase(inMemory: true)
    try await database.migrate(); try await other.migrate()
    let id = try await database.commitTextPoint(text: "Swift 内存管理")
    try await database.saveFacetOverride(pointID: id, dimension: .project, values: [" 点界 ", "点界"])
    try await database.saveFacetOverride(pointID: id, dimension: .topic, values: [])
    let saved = try await database.facetOverrides()
    #expect(saved.count == 2)
    #expect(saved.first { $0.dimension == .project }?.values == ["点界"])
    #expect(try await other.facetOverrides().isEmpty)
    try await database.saveFacetOverride(pointID: id, dimension: .topic, values: nil)
    #expect(try await database.facetOverrides().count == 1)
    #expect(try await database.pointDetail(id: id).sourceText == "Swift 内存管理")
    try await database.saveFacetOverride(pointID: id, dimension: .domain, values: ["lcc:QA76.75-76.765"])
    #expect(try await database.facetOverrides().first { $0.dimension == .domain }?.values == ["lcc:QA76.75-76.765"])
    do {
        try await database.saveFacetOverride(pointID: id, dimension: .domain, values: ["not-a-domain"])
        Issue.record("Accepted unknown controlled term")
    } catch { }
    _ = try await database.deletePoint(id: id)
    #expect(try await database.facetOverrides().isEmpty)
}
