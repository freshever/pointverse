import Foundation
import Testing
@testable import PointVerseKit

private enum StubFailure: Error { case request }

@Test func hierarchicalClassificationStartsWithAllRootsAndCanChooseUnrecalledSoftware() async throws {
    let result = try await LCCHierarchyClassifier.classify { options, parent in
        if parent == nil {
            #expect(Set(options) == Set(LCCHierarchyClassifier.roots))
            #expect(options.count == 21)
            return ("{\"status\":\"suggested\",\"ids\":[\"lcc:Q\"],\"reason\":\"主要是计算机话题\"}", "stub-model")
        }
        #expect(parent == "lcc:Q")
        #expect(options.contains("lcc:QA76.75-76.765"))
        #expect(!options.contains("lcc:TX"))
        return ("{\"status\":\"suggested\",\"ids\":[\"lcc:QA76.75-76.765\"],\"reason\":\"讨论代码内存管理\"}", "stub-model")
    }
    #expect(result.decision.ids == ["lcc:QA76.75-76.765"])
    #expect(result.modelID == "stub-model")
    #expect(result.refinementIssue == nil)
}

@Test func uncertainInvalidAndFailedRefinementKeepBroadCategory() async throws {
    for mode in 0..<4 {
        let result = try await LCCHierarchyClassifier.classify { _, parent in
            if parent == nil {
                return ("{\"status\":\"suggested\",\"ids\":[\"lcc:Q\"],\"reason\":\"科学探索\"}", "model")
            }
            switch mode {
            case 0: return ("{\"status\":\"uncertain\",\"ids\":[],\"reason\":\"细分类不明确\"}", "model")
            case 1: return ("invalid json", "model")
            case 2: throw StubFailure.request
            default: return ("{\"status\":\"suggested\",\"ids\":[\"lcc:TX\"],\"reason\":\"跑错分支\"}", "model")
            }
        }
        #expect(result.decision.status == .suggested)
        #expect(result.decision.ids == ["lcc:Q"])
        #expect((result.refinementIssue != nil) == (mode != 0))
    }
}

@Test func broadFailuresAreDistinctFromUncertaintyAndCanRetry() async throws {
    let entry = PointMapEntry(point: .init(id: PointID(), title: "", createdAt: Date(), transcriptState: nil), content: "内容", localeIdentifier: "zh-CN")
    let failure = try await LCCHierarchyClassifier.classify { _, _ in throw StubFailure.request }
    let malformed = try await LCCHierarchyClassifier.classify { _, _ in ("bad json", "actual-model") }
    let uncertain = try await LCCHierarchyClassifier.classify { _, parent in
        #expect(parent == nil)
        return ("{\"status\":\"uncertain\",\"ids\":[],\"reason\":\"没有实质内容\"}", "actual-model")
    }
    #expect(failure.decision.status == .failed)
    #expect(malformed.decision.status == .failed)
    #expect(malformed.modelID == "actual-model")
    #expect(uncertain.decision.status == .uncertain)
    for result in [failure, malformed, uncertain] {
        let review = LCCClassificationReview(entry: entry, embeddingModelID: "unused", judgeModelID: result.modelID,
            candidates: [], decision: result.decision)
        #expect(review.canRetryWithModel == (result.decision.status == .failed))
        #expect(review.primaryRecommendationID == nil)
    }
}

@Test func harmlessModelFormattingDoesNotDiscardValidClassification() throws {
    let result = try LCCClassificationDecision.parse("建议如下：\n{\"ids\":[\" Q \"],\"reason\":\"讨论科学\"}\n供参考", allowed: ["lcc:Q"])
    #expect(result.ids == ["lcc:Q"])
    #expect(result.status == .suggested)
    let missingReason = try LCCClassificationDecision.parse("{\"ids\":[\"Q\"]}", allowed: ["lcc:Q"])
    #expect(!missingReason.reason.isEmpty)
    do {
        _ = try LCCClassificationDecision.parse("{\"ids\":[\"FAKE\"]}", allowed: ["lcc:Q"])
        Issue.record("Accepted invented ID")
    } catch { }
}

@Test func hierarchicalClassificationPropagatesCancellation() async {
    do {
        _ = try await LCCHierarchyClassifier.classify { _, _ in throw CancellationError() }
        // A cancelled provider must not be persisted as a normal model failure.
        Issue.record("Cancellation was swallowed")
    } catch is CancellationError { } catch { Issue.record("Unexpected error") }
}
