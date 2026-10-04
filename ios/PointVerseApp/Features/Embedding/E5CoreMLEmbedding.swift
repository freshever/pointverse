@preconcurrency import CoreML
import Foundation
import PointVerseKit
import Tokenizers

enum E5EmbeddingLoadError: LocalizedError {
    case coreML(String)
    case tokenizer(String)

    var errorDescription: String? {
        switch self {
        case .coreML(let message): "Core ML 模型无法加载：\(message)"
        case .tokenizer(let message): "Tokenizer 无法加载：\(message)"
        }
    }
}

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
        let model: MLModel
        do {
            model = try MLModel(contentsOf: modelURL, configuration: configuration)
            PointVerseLog.embedding.info("E5 Core ML model loaded")
        } catch {
            let nsError = error as NSError
            PointVerseLog.embedding.error("E5 Core ML load failed domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) message=\(nsError.localizedDescription, privacy: .public)")
            throw E5EmbeddingLoadError.coreML("\(nsError.domain) (\(nsError.code)): \(nsError.localizedDescription)")
        }
        let tokenizer: any Tokenizer
        do {
            tokenizer = try await AutoTokenizer.from(modelFolder: tokenizerFolder)
            PointVerseLog.embedding.info("E5 tokenizer loaded")
        } catch {
            let nsError = error as NSError
            PointVerseLog.embedding.error("E5 tokenizer load failed domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) message=\(nsError.localizedDescription, privacy: .public)")
            throw E5EmbeddingLoadError.tokenizer("\(nsError.domain) (\(nsError.code)): \(nsError.localizedDescription)")
        }
        return E5CoreMLEmbedding(model: model, tokenizer: tokenizer, maxLength: maxLength)
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
