import Foundation
import PointVerseKit
import llama

public actor QwenTitleGenerator {
    private let registry: ModelRegistry
    private let executionGate: ModelExecutionGate
    private var engine: LlamaEngine?
    private var loadedModelPath: String?

    public init(registry: ModelRegistry, executionGate: ModelExecutionGate) {
        self.registry = registry
        self.executionGate = executionGate
    }

    public func releaseResources() {
        engine = nil
        loadedModelPath = nil
        PointVerseLog.storage.info("Language model resources released")
    }

    public func generateTitle(transcript: String, conversation: [ConversationMessage], localeIdentifier: String) async throws -> String {
        await executionGate.acquire()
        defer { releaseAfterExecution() }
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
        await executionGate.acquire()
        defer { releaseAfterExecution() }
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

    public func translateImagePromptToEnglish(_ source: String, localeIdentifier: String) async throws -> String {
        await executionGate.acquire()
        defer { releaseAfterExecution() }
        // Image generation has a much larger memory peak than text inference.
        // Drop any title/chat model cached by earlier operations before deciding
        // whether this prompt needs translation.
        engine = nil
        loadedModelPath = nil
        let compactSource = Self.compactImagePrompt(source)
        let normalizedLocale = localeIdentifier.lowercased()
        if normalizedLocale.hasPrefix("en"), compactSource.unicodeScalars.allSatisfy({ $0.isASCII }) { return compactSource }
        guard let manifest = await resolveInstalledModel() else { throw PointVerseError.modelNotInstalled }
        let modelURL = await registry.installedURL(for: manifest)
        try loadEngine(modelURL: modelURL)
        defer {
            engine = nil
            loadedModelPath = nil
            PointVerseLog.storage.info("Language model released before image pipeline load")
        }
        let safeSource = compactSource
            .replacingOccurrences(of: "<|im_start|>", with: "")
            .replacingOccurrences(of: "<|im_end|>", with: "")
        let prompt = """
        <|im_start|>system
        Rewrite the user's image request as a concise English Stable Diffusion prompt of at most 40 words. State the main subject first, then a clear camera angle, framing, subject placement, environment, style, lighting, and color. For people or animals, describe a natural pose and visible body parts unambiguously. Avoid conflicting styles and repeated quality adjectives. Do not add explanations, quotation marks, labels, or negative prompts. Output English only on one line.<|im_end|>
        <|im_start|>user
        \(safeSource)<|im_end|>
        <|im_start|>assistant
        <think>

        </think>

        """
        guard let raw = try engine?.complete(prompt: prompt, maximumTokens: 64) else {
            throw PointVerseError.invalidModelOutput
        }
        let translated = (raw.components(separatedBy: "<|im_end|>").first ?? raw)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'“”‘’")))
        guard !translated.isEmpty else { throw PointVerseError.invalidModelOutput }
        return Self.compactImagePrompt(translated)
    }

    private static func compactImagePrompt(_ value: String) -> String {
        let oneLine = value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let words = oneLine.split(separator: " ")
        if words.count > 40 { return words.prefix(40).joined(separator: " ") }
        return String(oneLine.prefix(280))
    }

    private func loadEngine(modelURL: URL) throws {
        guard loadedModelPath != modelURL.path || engine == nil else { return }
        engine = try LlamaEngine(modelURL: modelURL)
        loadedModelPath = modelURL.path
    }

    private func releaseAfterExecution() {
        engine = nil
        loadedModelPath = nil
        Task { await executionGate.release() }
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

public actor QwenVisionGenerator {
    private let registry: ModelRegistry
    private let executionGate: ModelExecutionGate
    private var engine: LlamaVisionEngine?

    public init(registry: ModelRegistry, executionGate: ModelExecutionGate) {
        self.registry = registry
        self.executionGate = executionGate
    }

    public func isAvailable() async -> Bool {
        let modelInstalled = await registry.isInstalled(.qwen3VL2BQ8)
        let projectorInstalled = await registry.isInstalled(.qwen3VL2BProjectorQ8)
        return modelInstalled && projectorInstalled
    }

    public func describe(imageData: Data, localeIdentifier: String) async throws -> String {
        await executionGate.acquire()
        defer {
            engine = nil
            Task { await executionGate.release() }
        }
        let modelManifest = ModelManifest.qwen3VL2BQ8
        let projectorManifest = ModelManifest.qwen3VL2BProjectorQ8
        guard await registry.isInstalled(modelManifest), await registry.isInstalled(projectorManifest) else {
            throw PointVerseError.modelNotInstalled
        }
        if engine == nil {
            engine = try LlamaVisionEngine(
                modelURL: await registry.installedURL(for: modelManifest),
                projectorURL: await registry.installedURL(for: projectorManifest)
            )
        }
        guard let engine else { throw PointVerseError.invalidModelOutput }
        return try engine.describe(imageData: imageData, language: Self.languageName(for: localeIdentifier))
    }

    public func releaseResources() {
        engine = nil
        PointVerseLog.storage.info("Vision model resources released")
    }

    private static func languageName(for identifier: String) -> String {
        let value = identifier.lowercased()
        if value.contains("hant") || value.contains("tw") || value.contains("hk") { return "Traditional Chinese" }
        if value.hasPrefix("zh") { return "Simplified Chinese" }
        if value.hasPrefix("ja") { return "Japanese" }
        return "English"
    }
}

private final class LlamaVisionEngine: @unchecked Sendable {
    private let model: OpaquePointer
    private let context: OpaquePointer
    private let multimodal: OpaquePointer

    init(modelURL: URL, projectorURL: URL) throws {
        llama_backend_init()
        var modelParameters = llama_model_default_params()
#if targetEnvironment(simulator)
        modelParameters.n_gpu_layers = 0
#endif
        guard let model = llama_model_load_from_file(modelURL.path, modelParameters) else { throw PointVerseError.modelNotInstalled }
        var contextParameters = llama_context_default_params()
        // Vision descriptions are deliberately short. A smaller KV cache and
        // micro-batch materially reduce the peak alongside the 2B model and mmproj.
        contextParameters.n_ctx = 1_024
        contextParameters.n_batch = 128
        contextParameters.n_ubatch = 128
        guard let context = llama_init_from_model(model, contextParameters) else {
            llama_model_free(model); throw PointVerseError.invalidModelOutput
        }
        var multimodalParameters = mtmd_context_params_default()
        // Keeping the projector on CPU avoids a large transient Metal allocation
        // that can make iOS terminate the process on memory-constrained devices.
        multimodalParameters.use_gpu = false
        multimodalParameters.image_min_tokens = 64
        multimodalParameters.image_max_tokens = 64
        guard let multimodal = mtmd_init_from_file(projectorURL.path, model, multimodalParameters),
              mtmd_support_vision(multimodal) else {
            llama_free(context); llama_model_free(model); throw PointVerseError.invalidModelOutput
        }
        self.model = model
        self.context = context
        self.multimodal = multimodal
    }

    deinit {
        mtmd_free(multimodal)
        llama_free(context)
        llama_model_free(model)
    }

    func describe(imageData: Data, language: String) throws -> String {
        // The engine is reused across attached photos to avoid reloading 2+ GB
        // of weights. Each photo must still start with a clean KV cache.
        llama_memory_clear(llama_get_memory(context), true)
        let wrapper = imageData.withUnsafeBytes { bytes in
            mtmd_helper_bitmap_init_from_buf(
                multimodal,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                imageData.count,
                false,
                mtmd_helper_init_opt_default()
            )
        }
        guard let bitmap = wrapper.bitmap else { throw PointVerseError.invalidModelOutput }
        defer { mtmd_bitmap_free(bitmap) }
        guard let chunks = mtmd_input_chunks_init() else { throw PointVerseError.invalidModelOutput }
        defer { mtmd_input_chunks_free(chunks) }
        let marker = String(cString: mtmd_get_marker(multimodal))
        let prompt = "<|im_start|>system\nDescribe the attached idea photo accurately in \(language). Mention important objects, scene, visible text, and intent. Be concise.<|im_end|>\n<|im_start|>user\n\(marker)\nDescribe this photo.<|im_end|>\n<|im_start|>assistant\n"
        var bitmapValue: OpaquePointer? = bitmap
        let tokenizeResult = prompt.withCString { textPointer in
            var input = mtmd_input_text(text: textPointer, text_len: strlen(textPointer), add_special: true, parse_special: true)
            return withUnsafePointer(to: &bitmapValue) { bitmapPointer in
                mtmd_tokenize(multimodal, chunks, &input, bitmapPointer, 1)
            }
        }
        guard tokenizeResult == 0 else { throw PointVerseError.invalidModelOutput }
        var position: llama_pos = 0
        guard mtmd_helper_eval_chunks(multimodal, context, chunks, 0, 0, 128, true, &position) == 0 else {
            throw PointVerseError.invalidModelOutput
        }

        let vocabulary = llama_model_get_vocab(model)
        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())!
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.2))
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32.random(in: 0..<(UInt32.max - 1))))
        var batch = llama_batch_init(1, 0, 1)
        defer { llama_batch_free(batch) }
        var output = ""
        for _ in 0..<96 {
            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocabulary, token) { break }
            var buffer = [CChar](repeating: 0, count: 256)
            let count = llama_token_to_piece(vocabulary, token, &buffer, Int32(buffer.count), 0, false)
            if count > 0 { output += String(decoding: buffer.prefix(Int(count)).map(UInt8.init(bitPattern:)), as: UTF8.self) }
            if output.contains("<|im_end|>") { break }
            batch.n_tokens = 1
            batch.token[0] = token
            batch.pos[0] = position
            batch.n_seq_id[0] = 1
            batch.seq_id[0]![0] = 0
            batch.logits[0] = 1
            guard llama_decode(context, batch) == 0 else { throw PointVerseError.invalidModelOutput }
            position += 1
        }
        let cleaned = (output.components(separatedBy: "<|im_end|>").first ?? output).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw PointVerseError.invalidModelOutput }
        return cleaned
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
