import Foundation
import PointVerseKit
import llama

public actor QwenTitleGenerator {
    private let registry: ModelRegistry
    private var engine: LlamaEngine?
    private var loadedModelPath: String?

    public init(registry: ModelRegistry) {
        self.registry = registry
    }

    public func generateTitle(transcript: String, conversation: [ConversationMessage], localeIdentifier: String) async throws -> String {
        guard let manifest = await resolveInstalledModel() else { throw PointVerseError.modelNotInstalled }
        let modelURL = await registry.installedURL(for: manifest)
        try loadEngine(modelURL: modelURL)

        let language = Self.languageName(for: localeIdentifier)
        let discussion = Self.formattedConversation(conversation)
        let prompt = """
        <|im_start|>system
        Create a short title for a saved voice note and its follow-up discussion. Treat the voice-note transcript as the primary source of the topic. Use the discussion only for important clarification or a refined direction. The title MUST be written in \(language), regardless of the source languages. Output only the title, without quotes, explanation, or ending punctuation. Maximum 20 characters for Chinese or Japanese, maximum 8 words for English.<|im_end|>
        <|im_start|>user
        Voice-note transcript:
        \(String(transcript.prefix(1_600)))

        Follow-up discussion:
        \(discussion)<|im_end|>
        <|im_start|>assistant
        <think>

        </think>

        """
        guard let rawTitle = try engine?.complete(prompt: prompt, maximumTokens: 48) else {
            throw PointVerseError.transcriptionFailed
        }
        let title = Self.clean(rawTitle, localeIdentifier: localeIdentifier)
        guard !title.isEmpty else { throw PointVerseError.invalidModelOutput }
        return title
    }

    public func generateReply(context: String, conversation: [ConversationMessage], localeIdentifier: String) async throws -> String {
        guard let manifest = await resolveInstalledModel() else { throw PointVerseError.modelNotInstalled }
        let modelURL = await registry.installedURL(for: manifest)
        try loadEngine(modelURL: modelURL)
        let language = Self.languageName(for: localeIdentifier)
        let turns: [String] = conversation.suffix(8).map { message -> String in
            let role = message.role == "assistant" ? "assistant" : "user"
            let safeText = String(message.text
                .replacingOccurrences(of: "<|im_start|>", with: "")
                .replacingOccurrences(of: "<|im_end|>", with: "").prefix(300))
            return "<|im_start|>\(role)\n\(safeText)<|im_end|>"
        }
        let history: String = turns.joined(separator: "\n")
        let prompt = """
        <|im_start|>system
        You are discussing a saved voice note with the user. The voice-note transcript is the primary and authoritative context. Directly answer the user's latest message in \(language). Never restate the conversation, never say "the user said", and never describe what the user asked. Say when the note does not contain enough information.
        Voice note:\n\(String(context.prefix(1_600)))<|im_end|>
        \(history)
        <|im_start|>assistant
        <think>

        </think>

        """
        guard let reply = try engine?.complete(prompt: prompt, maximumTokens: 192)
            .trimmingCharacters(in: .whitespacesAndNewlines), !reply.isEmpty else {
            throw PointVerseError.invalidModelOutput
        }
        return reply.components(separatedBy: "<|im_end|>").first ?? reply
    }

    private func loadEngine(modelURL: URL) throws {
        guard loadedModelPath != modelURL.path || engine == nil else { return }
        engine = try LlamaEngine(modelURL: modelURL)
        loadedModelPath = modelURL.path
    }

    private func resolveInstalledModel() async -> ModelManifest? {
        guard let preferred = ModelSelection.selectedLanguageModel() else { return nil }
        guard let resolved = await registry.resolveInstalledModel(preferred: preferred, candidates: ModelSelection.languageModels) else {
            PointVerseLog.transcription.error("No installed language model found; preferred=\(preferred.id, privacy: .public)")
            return nil
        }
        if resolved.id != preferred.id {
            UserDefaults.standard.set(resolved.id, forKey: ModelSelection.languageDefaultsKey)
            PointVerseLog.transcription.notice("Preferred model unavailable; selected installed fallback=\(resolved.id, privacy: .public)")
        } else {
            PointVerseLog.transcription.info("Selected installed language model=\(resolved.id, privacy: .public)")
        }
        return resolved
    }

    private static func formattedConversation(_ messages: [ConversationMessage]) -> String {
        guard !messages.isEmpty else { return "No follow-up discussion yet." }
        return messages.suffix(4).map {
            ($0.role == "assistant" ? "Assistant: " : "User: ") + String($0.text.prefix(250))
        }.joined(separator: "\n")
    }

    private static func languageName(for identifier: String) -> String {
        let value = identifier.lowercased()
        if value.isEmpty { return "the same language as the voice-note transcript" }
        if value.contains("hant") || value.contains("tw") || value.contains("hk") { return "Traditional Chinese" }
        if value.hasPrefix("zh") { return "Simplified Chinese" }
        if value.hasPrefix("ja") { return "Japanese" }
        return "English"
    }

    private static func clean(_ value: String, localeIdentifier: String) -> String {
        var title = value
            .components(separatedBy: "<|im_end|>").first ?? value
        title = title.components(separatedBy: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? title
        title = title.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'“”‘’。.!！?？:：")))
        if localeIdentifier.lowercased().hasPrefix("en") {
            return title.split(separator: " ").prefix(8).joined(separator: " ")
        }
        return String(title.prefix(20))
    }
}

private final class LlamaEngine: @unchecked Sendable {
    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocabulary: OpaquePointer
    private var sampler: UnsafeMutablePointer<llama_sampler>
    private var batch: llama_batch

    init(modelURL: URL) throws {
        llama_backend_init()
        var modelParameters = llama_model_default_params()
#if targetEnvironment(simulator)
        modelParameters.n_gpu_layers = 0
#endif
        guard let model = llama_model_load_from_file(modelURL.path, modelParameters) else {
            throw PointVerseError.modelNotInstalled
        }
        var contextParameters = llama_context_default_params()
        contextParameters.n_ctx = 4_096
        let threads = Int32(max(1, min(8, ProcessInfo.processInfo.processorCount - 2)))
        contextParameters.n_threads = threads
        contextParameters.n_threads_batch = threads
        guard let context = llama_init_from_model(model, contextParameters) else {
            llama_model_free(model)
            throw PointVerseError.transcriptionFailed
        }
        self.model = model
        self.context = context
        vocabulary = llama_model_get_vocab(model)
        batch = llama_batch_init(4_096, 0, 1)
        sampler = Self.makeSampler()
    }

    deinit {
        llama_sampler_free(sampler)
        llama_batch_free(batch)
        llama_free(context)
        llama_model_free(model)
    }

    func complete(prompt: String, maximumTokens: Int) throws -> String {
        llama_memory_clear(llama_get_memory(context), true)
        llama_sampler_free(sampler)
        sampler = Self.makeSampler()
        let tokens = tokenize(prompt)
        guard !tokens.isEmpty, tokens.count + maximumTokens < Int(llama_n_ctx(context)) else {
            throw PointVerseError.invalidModelOutput
        }

        clearBatch()
        for (position, token) in tokens.enumerated() {
            add(token: token, position: Int32(position), logits: position == tokens.count - 1)
        }
        guard llama_decode(context, batch) == 0 else { throw PointVerseError.invalidModelOutput }

        var result = ""
        var position = Int32(tokens.count)
        for _ in 0..<maximumTokens {
            let token = llama_sampler_sample(sampler, context, batch.n_tokens - 1)
            if llama_vocab_is_eog(vocabulary, token) { break }
            result += piece(for: token)
            if result.contains("<|im_end|>") || result.contains("\n") { break }
            clearBatch()
            add(token: token, position: position, logits: true)
            guard llama_decode(context, batch) == 0 else { throw PointVerseError.invalidModelOutput }
            position += 1
        }
        return result
    }

    private static func makeSampler() -> UnsafeMutablePointer<llama_sampler> {
        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())!
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.6))
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32.random(in: 0..<(UInt32.max - 1))))
        return sampler
    }

    private func tokenize(_ text: String) -> [llama_token] {
        let capacity = text.utf8.count + 16
        var tokens = [llama_token](repeating: 0, count: capacity)
        let count = llama_tokenize(vocabulary, text, Int32(text.utf8.count), &tokens, Int32(capacity), true, true)
        guard count > 0 else { return [] }
        return Array(tokens.prefix(Int(count)))
    }

    private func piece(for token: llama_token) -> String {
        var buffer = [CChar](repeating: 0, count: 64)
        var count = llama_token_to_piece(vocabulary, token, &buffer, Int32(buffer.count), 0, false)
        if count < 0 {
            buffer = [CChar](repeating: 0, count: Int(-count))
            count = llama_token_to_piece(vocabulary, token, &buffer, Int32(buffer.count), 0, false)
        }
        guard count > 0 else { return "" }
        return String(decoding: buffer.prefix(Int(count)).map(UInt8.init(bitPattern:)), as: UTF8.self)
    }

    private func clearBatch() {
        batch.n_tokens = 0
    }

    private func add(token: llama_token, position: llama_pos, logits: Bool) {
        let index = Int(batch.n_tokens)
        batch.token[index] = token
        batch.pos[index] = position
        batch.n_seq_id[index] = 1
        batch.seq_id[index]![0] = 0
        batch.logits[index] = logits ? 1 : 0
        batch.n_tokens += 1
    }
}
