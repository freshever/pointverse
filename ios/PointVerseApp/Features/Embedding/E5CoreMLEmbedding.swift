@preconcurrency import CoreML
import Foundation
import PointVerseKit
import Tokenizers

actor E5CoreMLEmbedding: PointEmbedding {
    nonisolated let modelID = EmbeddingModelIdentity.multilingualE5Small
    nonisolated let dimension = 384
    private let model: MLModel
    private let tokenizer: any Tokenizer
    private let maxLength: Int

    private init(model: MLModel, tokenizer: any Tokenizer, maxLength: Int) {
        self.model = model
        self.tokenizer = tokenizer
        self.maxLength = maxLength
    }

    static func load(modelURL: URL, tokenizerFolder: URL, maxLength: Int = 128) async throws -> E5CoreMLEmbedding {
        let configuration = MLModelConfiguration()
        // The INT8-weight / Float32-compute XLM-R graph currently aborts inside
        // MPSGraph optimization on real devices when `.all` selects GPU/ANE.
        // CPU inference is numerically verified and, unlike a thrown error, the
        // Metal assertion cannot be recovered from at runtime.
        configuration.computeUnits = .cpuOnly
        async let tokenizer = AutoTokenizer.from(modelFolder: tokenizerFolder)
        let model = try MLModel(contentsOf: modelURL, configuration: configuration)
        return try await E5CoreMLEmbedding(model: model, tokenizer: tokenizer, maxLength: maxLength)
    }

    func encode(_ text: String) async throws -> [Float] {
        // E5 recommends the query prefix for symmetric similarity tasks such as
        // clustering, while query/passsage is reserved for asymmetric retrieval.
        var ids = tokenizer.encode(text: "query: \(text)")
        ids = Array(ids.prefix(maxLength))
        let tokenCount = ids.count
        let paddingID = tokenizer.convertTokenToId("<pad>") ?? 1
        if ids.count < maxLength { ids.append(contentsOf: repeatElement(paddingID, count: maxLength - ids.count)) }
        let mask = (0..<maxLength).map { $0 < tokenCount ? Int32(1) : Int32(0) }
        let inputIDs = try multiArray(ids.map(Int32.init))
        let attentionMask = try multiArray(mask)
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: inputIDs),
            "attention_mask": MLFeatureValue(multiArray: attentionMask),
        ])
        let output = try await model.prediction(from: provider, options: MLPredictionOptions())
        guard let hidden = output.featureValue(for: "last_hidden_state")?.multiArrayValue,
              hidden.shape.count == 3, hidden.shape[2].intValue == dimension else {
            throw PointVerseError.modelLoadFailed
        }
        var pooled = Array(repeating: Float.zero, count: dimension)
        for token in 0..<tokenCount {
            for column in 0..<dimension {
                pooled[column] += hidden[[0, token, column] as [NSNumber]].floatValue
            }
        }
        guard tokenCount > 0 else { throw PointVerseError.invalidModelOutput }
        return EmbeddingMath.normalize(pooled.map { $0 / Float(tokenCount) })
    }

    private func multiArray(_ values: [Int32]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1, NSNumber(value: values.count)], dataType: .int32)
        for index in values.indices { array[index] = NSNumber(value: values[index]) }
        return array
    }
}
