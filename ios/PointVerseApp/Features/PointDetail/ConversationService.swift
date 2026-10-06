import Foundation
import PointVerseKit
import QwenAdapter

actor ConversationService {
    enum SendResult { case succeeded, modelUnavailable, failed }
    private let repository: any PointRepository
    private let generator: QwenTitleGenerator

    init(repository: any PointRepository, generator: QwenTitleGenerator) {
        self.repository = repository
        self.generator = generator
    }

    func send(pointID: PointID, text: String, languageIdentifier: String, role: ConversationRole) async -> SendResult {
        do {
            try await repository.appendConversationMessage(pointID: pointID, role: "user", text: text)
            let detail = try await repository.pointDetail(id: pointID)
            let messages = try await repository.conversationMessages(pointID: pointID).filter {
                !($0.role == "assistant" && ["user", "assistant"].contains($0.text.lowercased()))
            }
            let imageText = try await repository.images(pointID: pointID).enumerated().compactMap { index, image in
                guard let text = image.recognizedText, !text.isEmpty else { return nil }
                return "Photo \(index + 1): " + String(text.prefix(180))
            }.joined(separator: "\n")
            let primaryText = detail.modality == "text" ? (detail.sourceText ?? "") : (detail.effectiveTranscript ?? "")
            let context = imageText.isEmpty
                ? primaryText
                : "Attached photos:\n" + imageText + "\n\nSaved content:\n" + String(primaryText.prefix(500))
            let reply = try await generator.generateReply(
                context: context,
                conversation: messages,
                localeIdentifier: languageIdentifier,
                role: role
            )
            try await repository.appendConversationMessage(pointID: pointID, role: "assistant", text: reply)
            return .succeeded
        } catch PointVerseError.modelNotInstalled {
            PointVerseLog.transcription.error("Local-model conversation failed: no installed language model resolved")
            return .modelUnavailable
        } catch {
            let nsError = error as NSError
            PointVerseLog.transcription.error("Local-model conversation failed: domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)")
            return .failed
        }
    }
}
