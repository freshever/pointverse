import Testing
@testable import PointVerseKit

@Test func longLanguagePromptsAreSplitWithinDecodeCapacityWithAbsolutePositions() throws {
    for count in [1, 127, 128, 129, 512, 2048, 3735] {
        let chunks = try LanguageModelBatchPlan.ranges(tokenCount: count, maximumNewTokens: 360,
                                                     contextSize: 4096, batchCapacity: 128)
        #expect(chunks.allSatisfy { !$0.isEmpty && $0.count <= 128 })
        #expect(chunks.flatMap { Array($0) } == Array(0..<count))
        #expect(chunks.last?.last == count - 1)
    }
    #expect(try LanguageModelBatchPlan.ranges(tokenCount: 129, maximumNewTokens: 360,
                                             contextSize: 4096, batchCapacity: 128) == [0..<128, 128..<129])
}

@Test func invalidLanguageBudgetsFailBeforeEnteringNativeDecode() {
    for (tokens, output, context, batch) in [
        (0, 360, 4096, 128), (3736, 360, 4096, 128), (4096, 360, 4096, 128),
        (10, 0, 4096, 128), (10, -1, 4096, 128), (10, 360, 4096, 0),
        (10, 4096, 4096, 128), (Int.max, 360, 4096, 128)
    ] {
        do {
            _ = try LanguageModelBatchPlan.ranges(tokenCount: tokens, maximumNewTokens: output,
                                                 contextSize: context, batchCapacity: batch)
            Issue.record("Accepted invalid context/batch budget")
        } catch { }
    }
}
