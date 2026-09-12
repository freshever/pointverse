import Foundation
import PointVerseKit
import QwenAdapter

actor ConversationService {
    private let repository: any PointRepository
    private let generator: QwenTitleGenerator

    init(repository: any PointRepository, generator: QwenTitleGenerator) {
        self.repository = repository
        self.generator = generator
    }

    func send(pointID: PointID, text: String, languageIdentifier: String) async -> Bool {
        do {
            try await repository.appendConversationMessage(pointID: pointID, role: "user", text: text)
            let detail = try await repository.pointDetail(id: pointID)
            let messages = try await repository.conversationMessages(pointID: pointID)
            let imageText = try await repository.images(pointID: pointID).enumerated().compactMap { index, image in
                guard let text = image.recognizedText, !text.isEmpty else { return nil }
                return "Photo \(index + 1): " + String(text.prefix(300))
            }.joined(separator: "\n")
            let context = imageText.isEmpty
                ? (detail.effectiveTranscript ?? "")
                : "Attached photos:\n" + imageText + "\n\nVoice note:\n" + String((detail.effectiveTranscript ?? "").prefix(700))
            let reply = try await generator.generateReply(
                context: context,
                conversation: messages,
                localeIdentifier: languageIdentifier
            )
            try await repository.appendConversationMessage(pointID: pointID, role: "assistant", text: reply)
            return true
        } catch {
            let nsError = error as NSError
            PointVerseLog.transcription.error("Local-model conversation failed: domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)")
            return false
        }
    }
}
