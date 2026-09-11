import Foundation
import PointVerseKit
import llama

public actor QwenTitleGenerator {
    private let registry: ModelRegistry
    private var engine: LlamaEngine?

    public init(registry: ModelRegistry) {
        self.registry = registry
    }

    public func generateTitle(transcript: String, localeIdentifier: String) async throws -> String {
        let manifest = ModelManifest.qwen3_0_6BQ8
        guard await registry.isInstalled(manifest) else { throw PointVerseError.modelNotInstalled }
        let modelURL = await registry.installedURL(for: manifest)
        if engine == nil { engine = try LlamaEngine(modelURL: modelURL) }

        let language = Self.languageName(for: localeIdentifier)
        let prompt = """
        <|im_start|>system
        You create a short title for a voice note. Output only the title in \(language), without quotes, explanation, or punctuation. Maximum 20 characters for Chinese or Japanese, maximum 8 words for English.<|im_end|>
        <|im_start|>user
        \(String(transcript.prefix(6_000)))<|im_end|>
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

    private static func languageName(for identifier: String) -> String {
        let value = identifier.lowercased()
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
    private let sampler: UnsafeMutablePointer<llama_sampler>
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
        contextParameters.n_ctx = 2_048
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
        batch = llama_batch_init(2_048, 0, 1)
        sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.2))
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(42))
    }

    deinit {
        llama_sampler_free(sampler)
        llama_batch_free(batch)
        llama_free(context)
        llama_model_free(model)
    }

    func complete(prompt: String, maximumTokens: Int) throws -> String {
        llama_memory_clear(llama_get_memory(context), true)
        llama_sampler_reset(sampler)
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
