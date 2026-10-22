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

    func send(pointID: PointID, text: String, languageIdentifier: String, role: ConversationRole,
              selectedPointIDs: [PointID] = []) async -> SendResult {
        do {
            try await repository.appendConversationMessage(pointID: pointID, role: "user", text: text, modelID: nil)
            let detail = try await repository.pointDetail(id: pointID)
            let messages = try await repository.conversationMessages(pointID: pointID).filter {
                !($0.role == "assistant" && ["user", "assistant"].contains($0.text.lowercased()))
            }
            let imageText = try await repository.images(pointID: pointID).enumerated().compactMap { index, image in
                guard let text = image.recognizedText, !text.isEmpty else { return nil }
                return "Photo \(index + 1): " + String(text.prefix(180))
            }.joined(separator: "\n")
            let primaryText = detail.modality == "text" ? (detail.sourceText ?? "") : (detail.effectiveTranscript ?? "")
            var context = imageText.isEmpty
                ? primaryText
                : "Attached photos:\n" + imageText + "\n\nSaved content:\n" + String(primaryText.prefix(500))
            for id in selectedPointIDs.prefix(3) where id != pointID {
                let previous = try await repository.pointDetail(id: id)
                let content = previous.modality == "text" ? previous.sourceText : previous.effectiveTranscript
                context += "\n\nUser-selected earlier thought [\(id.rawValue.uuidString)] — \(previous.title):\n" + String((content ?? "").prefix(1000))
            }
            if !selectedPointIDs.isEmpty {
                context += "\n\nContinue the user's current question using these earlier thoughts. Identify what was already considered and suggest a concrete next step. Cite thought titles when drawing on them. Do not assume semantic similarity proves agreement or invent missing history."
            }
            let reply = try await generator.generateReply(
                context: context,
                conversation: messages,
                localeIdentifier: languageIdentifier,
                role: role
            )
            try await repository.appendConversationMessage(
                pointID: pointID,
                role: "assistant",
                text: reply.text,
                modelID: reply.modelID
            )
            return .succeeded
        } catch PointVerseError.modelNotInstalled {
            PointVerseLog.transcription.error("Local-model conversation failed: no installed language model resolved")
            return .modelUnavailable
        } catch {
            let nsError = error as NSError
            PointVerseLog.transcription.error("Language-model conversation failed: domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) message=\(nsError.localizedDescription, privacy: .public)")
            return .failed
        }
    }

}
