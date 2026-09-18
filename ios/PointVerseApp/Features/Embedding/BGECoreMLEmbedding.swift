@preconcurrency import CoreML
import Foundation
import PointVerseKit

actor BGECoreMLEmbedding: PointEmbedding {
    nonisolated let modelID = EmbeddingModelIdentity.bgeSmallZhV15
    nonisolated let dimension = 512
    private let model: MLModel
    private let tokenizer: BGEWordPieceTokenizer
    private let maxLength: Int

    init(modelURL: URL, vocabularyURL: URL, maxLength: Int = 128) throws {
        let configuration = MLModelConfiguration()
#if targetEnvironment(simulator)
        // The simulator has no Neural Engine. Explicit CPU execution also avoids
        // Core ML trying an unavailable accelerator while loading a large ML Program.
        configuration.computeUnits = .cpuOnly
#else
        configuration.computeUnits = ProcessInfo.processInfo.isiOSAppOnMac ? .cpuOnly : .all
#endif
        model = try MLModel(contentsOf: modelURL, configuration: configuration)
        tokenizer = try BGEWordPieceTokenizer(vocabularyURL: vocabularyURL)
        self.maxLength = maxLength
    }

    func encode(_ text: String) async throws -> [Float] {
        let encoded = tokenizer.encode(text, maxLength: maxLength)
        let ids = try multiArray(encoded.ids)
        let mask = try multiArray(encoded.mask)
        let zeros = try multiArray(Array(repeating: 0, count: maxLength))
        let inputNames = model.modelDescription.inputDescriptionsByName.keys
        var values: [String: MLFeatureValue] = [:]
        if inputNames.contains("input_ids") { values["input_ids"] = MLFeatureValue(multiArray: ids) }
        if inputNames.contains("attention_mask") { values["attention_mask"] = MLFeatureValue(multiArray: mask) }
        if inputNames.contains("token_type_ids") { values["token_type_ids"] = MLFeatureValue(multiArray: zeros) }
        let output = try await model.prediction(
            from: MLDictionaryFeatureProvider(dictionary: values),
            options: MLPredictionOptions()
        )
        guard let hidden = output.featureNames.compactMap({ output.featureValue(for: $0)?.multiArrayValue }).first(where: { $0.shape.count == 3 }) else {
            throw PointVerseError.modelLoadFailed
        }
        let width = hidden.shape[2].intValue
        guard width == dimension else { throw PointVerseError.modelLoadFailed }
        let cls = (0..<width).map { hidden[[0, 0, $0] as [NSNumber]].floatValue }
        return EmbeddingMath.normalize(cls)
    }

    private func multiArray(_ values: [Int32]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1, NSNumber(value: values.count)], dataType: .int32)
        for index in values.indices { array[index] = NSNumber(value: values[index]) }
        return array
    }
}
