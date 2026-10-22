import Foundation

/// Context capacity and decode batch capacity are independent limits.
public enum LanguageModelBatchPlan {
    public static func ranges(tokenCount: Int, maximumNewTokens: Int, contextSize: Int,
                              batchCapacity: Int) throws -> [Range<Int>] {
        guard tokenCount > 0, maximumNewTokens > 0, contextSize > maximumNewTokens,
              tokenCount < contextSize - maximumNewTokens, batchCapacity > 0 else {
            throw LanguageModelInputError.invalidBudget
        }
        return stride(from: 0, to: tokenCount, by: batchCapacity).map { start in
            start..<(start + min(batchCapacity, tokenCount - start))
        }
    }
}

public enum LanguageModelInputError: LocalizedError {
    case invalidBudget
    public var errorDescription: String? {
        "输入过长或本地模型推理配置无效，已停止本次生成以避免崩溃。请缩短内容或选择支持更长上下文的模型。"
    }
}
