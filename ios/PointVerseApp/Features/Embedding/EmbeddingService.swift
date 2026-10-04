import Foundation
import PointVerseKit

actor EmbeddingService {
    static let didChangeNotification = Notification.Name("PointVerseEmbeddingDidChange")
    private let repository: any PointRepository
    private let provider: any PointEmbedding

    init(repository: any PointRepository, provider: any PointEmbedding) {
        self.repository = repository
        self.provider = provider
    }

    func resumePending() async {
        do {
            let documents = try await repository.queuedEmbeddingDocuments(modelID: provider.modelID)
            let usable = documents.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            PointVerseLog.embedding.info("Embedding backfill found \(documents.count, privacy: .public) missing records; \(usable.count, privacy: .public) contain text")
            for document in usable {
                do {
                    PointVerseLog.embedding.info("Encoding point=\(document.pointID.rawValue.uuidString, privacy: .public) revision=\(document.revision, privacy: .public) characters=\(document.text.count, privacy: .public)")
                    let vector = try await provider.encode(document.text)
                    guard vector.count == provider.dimension else { throw PointVerseError.invalidModelOutput }
                    try await repository.saveEmbedding(.init(pointID: document.pointID, revision: document.revision,
                                                             modelID: provider.modelID, vector: vector))
                    PointVerseLog.embedding.info("Embedding saved point=\(document.pointID.rawValue.uuidString, privacy: .public) dimension=\(vector.count, privacy: .public)")
                    await MainActor.run {
                        NotificationCenter.default.post(
                            name: Self.didChangeNotification,
                            object: document.pointID.rawValue.uuidString
                        )
                    }
                } catch {
                    PointVerseLog.embedding.error("Embedding failed point=\(document.pointID.rawValue.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        } catch {
            PointVerseLog.embedding.error("Embedding backfill query failed: \(String(describing: error), privacy: .public)")
        }
    }
}
