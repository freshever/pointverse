import Foundation
import PointVerseKit

actor EmbeddingService {
    private let repository: any PointRepository
    private let provider: any PointEmbedding

    init(repository: any PointRepository, provider: any PointEmbedding) {
        self.repository = repository
        self.provider = provider
    }

    func resumePending() async {
        do {
            let documents = try await repository.queuedEmbeddingDocuments(modelID: provider.modelID)
            for document in documents where !document.text.isEmpty {
                let vector = try await provider.encode(document.text)
                guard vector.count == provider.dimension else { throw PointVerseError.invalidModelOutput }
                try await repository.saveEmbedding(.init(pointID: document.pointID, revision: document.revision,
                                                         modelID: provider.modelID, vector: vector))
            }
        } catch {
            PointVerseLog.embedding.error("Embedding queue paused: \(String(describing: error), privacy: .public)")
        }
    }
}
