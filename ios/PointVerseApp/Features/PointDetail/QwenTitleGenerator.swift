import Foundation
import Edge0MLX
import PointVerseKit
import llama

public enum ConversationRole: String, CaseIterable, Sendable {
    case concise, explore, organize, creative

    var instruction: String {
        switch self {
        case .concise: return "Answer concisely in 1 to 3 sentences."
        case .explore: return "Explore the idea with one useful observation and one thoughtful question."
        case .organize: return "Organize the answer into a compact, actionable structure."
        case .creative: return "Offer an imaginative interpretation or direction while staying relevant."
        }
    }

    var maximumTokens: Int { self == .concise ? 96 : 160 }
}

public actor QwenTitleGenerator {
    private let registry: ModelRegistry
    private let executionGate: ModelExecutionGate
    private var engine: LlamaEngine?
    private var edge0Engine: Edge0ChatEngine?
    private var loadedModelPath: String?

    public init(registry: ModelRegistry, executionGate: ModelExecutionGate) {
        self.registry = registry
        self.executionGate = executionGate
    }

    public func releaseResources() {
        engine = nil
        edge0Engine = nil
        loadedModelPath = nil
        PointVerseLog.storage.info("Language model resources released")
    }

    public func generateTitle(transcript: String, conversation: [ConversationMessage], localeIdentifier: String) async throws -> String {
        await executionGate.acquire()
        defer { releaseAfterExecution() }
        let manifest = try await prepareSelectedEngine()

        let language = Self.languageName(for: localeIdentifier)
        let discussion = Self.formattedConversation(conversation)
        let assistantPreamble = manifest.map(Self.assistantPreamble(for:)) ?? ""
        let prompt = """
        <|im_start|>system
        Create a short title for a saved voice note and its follow-up discussion. Treat the voice-note transcript as the primary source of the topic. Use the discussion only for important clarification or a refined direction. The title MUST be written in \(language), regardless of the source languages. Output only the title, without quotes, explanation, or ending punctuation. Maximum 20 characters for Chinese or Japanese, maximum 8 words for English.<|im_end|>
        <|im_start|>user
        Voice-note transcript:
        \(String(transcript.prefix(1_600)))

        Follow-up discussion:
        \(discussion)<|im_end|>
        <|im_start|>assistant
        \(assistantPreamble)
        """
        guard let rawTitle = try complete(prompt: prompt, maximumTokens: 48) else {
            throw PointVerseError.transcriptionFailed
        }
        let title = Self.clean(rawTitle, localeIdentifier: localeIdentifier)
        guard !title.isEmpty else { throw PointVerseError.invalidModelOutput }
        return title
    }

    public func generateReply(context: String, conversation: [ConversationMessage], localeIdentifier: String,
                              role: ConversationRole = .concise) async throws -> String {
        await executionGate.acquire()
        defer { releaseAfterExecution() }
        let manifest = try await prepareSelectedEngine()
        let language = Self.languageName(for: localeIdentifier)
        let assistantPreamble = manifest.map(Self.assistantPreamble(for:)) ?? ""
        let turns: [String] = conversation.suffix(6).map { message -> String in
            let role = message.role == "assistant" ? "assistant" : "user"
            let safeText = String(message.text
                .replacingOccurrences(of: "<|im_start|>", with: "")
                .replacingOccurrences(of: "<|im_end|>", with: "").prefix(180))
            return "<|im_start|>\(role)\n\(safeText)<|im_end|>"
        }
        let history: String = turns.joined(separator: "\n")
        let prompt = """
        <|im_start|>system
        You are discussing saved content with the user. The saved content is the primary and authoritative context. Directly answer the user's latest message in \(language). \(role.instruction) Never restate the conversation, never say "the user said", and never describe what the user asked. Say when the saved content does not contain enough information.
        Saved content:\n\(String(context.prefix(900)))<|im_end|>
        \(history)
        <|im_start|>assistant
        \(assistantPreamble)
        """
        guard let rawReply = try complete(prompt: prompt, maximumTokens: role.maximumTokens, stopAtNewline: false) else {
            throw PointVerseError.invalidModelOutput
        }
        let reply = Self.cleanReply(rawReply)
        if !reply.isEmpty, !["user", "assistant"].contains(reply.lowercased()) { return reply }

        // Small models occasionally echo a ChatML role token instead of the
        // answer. Retry once with only the latest question and a shorter prompt.
        let latestQuestion = conversation.last(where: { $0.role == "user" })?.text ?? ""
        let retryPrompt = """
        <|im_start|>system
        Answer the question using the saved content. Reply in \(language). \(role.instruction) Do not output role names or labels.<|im_end|>
        <|im_start|>user
        Saved content:\n\(String(context.prefix(700)))

        Question:\n\(String(latestQuestion.prefix(240)))<|im_end|>
        <|im_start|>assistant
        \(assistantPreamble)
        """
        guard let retried = try complete(prompt: retryPrompt, maximumTokens: role.maximumTokens, stopAtNewline: false) else {
            throw PointVerseError.invalidModelOutput
        }
        let cleanedRetry = Self.cleanReply(retried)
        guard !cleanedRetry.isEmpty, !["user", "assistant"].contains(cleanedRetry.lowercased()) else {
            throw PointVerseError.invalidModelOutput
        }
        return cleanedRetry
    }

    /// Generates diverse, text-only records for the isolated test database.
    /// Small local models are more reliable with compact batches, so a +100
    /// request is split internally while the model remains behind the shared
    /// execution gate.
    public func generateTestTexts(count: Int, startingAt start: Int) async throws -> [String] {
        guard count > 0 else { return [] }
        await executionGate.acquire()
        defer { releaseAfterExecution() }
        let manifest = try await prepareSelectedEngine()

        var result: [String] = []
        while result.count < count {
            let batchCount = min(10, count - result.count)
            let batchNumber = start + result.count
            let prompt = """
            <|im_start|>system
            Generate exactly \(batchCount) distinct short notes for testing a multilingual semantic map. Cover clearly different subjects such as technology, food, nature, astronomy, exercise, art, finance, travel, emotions, and history. Include some Chinese and some English. Do not use sample numbers, labels, explanations, markdown, or duplicate ideas. Return only a valid JSON array of \(batchCount) strings.<|im_end|>
            <|im_start|>user
            Create test batch \(batchNumber / 10 + 1). Use ideas different from ordinary examples in earlier batches.<|im_end|>
            <|im_start|>assistant
            \(manifest.map(Self.assistantPreamble(for:)) ?? "")
            """
            guard let raw = try complete(prompt: prompt, maximumTokens: 640, stopAtNewline: false),
                  let batch = Self.parseTestTextArray(raw, expectedCount: batchCount) else {
                throw PointVerseError.invalidModelOutput
            }
            result.append(contentsOf: batch)
        }
        return Array(result.prefix(count))
    }

    public func translateImagePromptToEnglish(_ source: String, localeIdentifier: String) async throws -> String {
        await executionGate.acquire()
        defer { releaseAfterExecution() }
        // Image generation has a much larger memory peak than text inference.
        // Drop any title/chat model cached by earlier operations before deciding
        // whether this prompt needs translation.
        engine = nil
        edge0Engine = nil
        loadedModelPath = nil
        let compactSource = Self.compactImagePrompt(source)
        let normalizedLocale = localeIdentifier.lowercased()
        if normalizedLocale.hasPrefix("en"), compactSource.unicodeScalars.allSatisfy({ $0.isASCII }) { return compactSource }
        let manifest = try await prepareSelectedEngine()
        let assistantPreamble = manifest.map(Self.assistantPreamble(for:)) ?? ""
        defer {
            engine = nil
            edge0Engine = nil
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
        \(assistantPreamble)
        """
        guard let raw = try complete(prompt: prompt, maximumTokens: 64) else {
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

    private static func parseTestTextArray(_ raw: String, expectedCount: Int) -> [String]? {
        guard let start = raw.firstIndex(of: "["), let end = raw.lastIndex(of: "]"), start <= end else { return nil }
        let payload = Data(raw[start...end].utf8)
        guard let decoded = try? JSONDecoder().decode([String].self, from: payload) else { return nil }
        let cleaned = decoded.map {
            $0.replacingOccurrences(of: "<|im_start|>", with: "")
                .replacingOccurrences(of: "<|im_end|>", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty && $0.count <= 240 }
        var seen = Set<String>()
        let unique = cleaned.filter { seen.insert($0.lowercased()).inserted }
        return unique.count == expectedCount ? unique : nil
    }

    private func loadEngine(modelURL: URL) throws {
        guard loadedModelPath != modelURL.path || engine == nil else { return }
        edge0Engine = nil
        engine = try LlamaEngine(modelURL: modelURL)
        loadedModelPath = modelURL.path
    }

    private func loadEdge0Engine(modelURL: URL) throws {
        guard loadedModelPath != modelURL.path || edge0Engine == nil else { return }
        engine = nil
        edge0Engine = try Edge0ChatEngine(modelURL: modelURL) { message in
            PointVerseLog.storage.info("Edge0: \(message, privacy: .public)")
        }
        loadedModelPath = modelURL.path
    }

    private func complete(prompt: String, maximumTokens: Int, stopAtNewline: Bool = true) throws -> String? {
        if let edge0Engine {
            // PointVerse requests are independent jobs. Resetting avoids leaking
            // one Point's context into the next title, judge, or prompt task.
            edge0Engine.reset()
            let result = try edge0Engine.reply(to: prompt, maxTokens: maximumTokens, thinking: false)
            return stopAtNewline ? result.text.components(separatedBy: .newlines).first : result.text
        }
        return try engine?.complete(prompt: prompt, maximumTokens: maximumTokens, stopAtNewline: stopAtNewline)
    }

    private func releaseAfterExecution() {
        engine = nil
        edge0Engine = nil
        loadedModelPath = nil
        Task { await executionGate.release() }
    }

    private func prepareSelectedEngine() async throws -> ModelManifest? {
        let selectedID = ModelSelection.selectedLanguageModelID()
        guard selectedID != ModelSelection.disabledLanguageModelID else { throw PointVerseError.modelNotInstalled }
        if selectedID == ModelSelection.edge0LanguageModelID {
            guard await registry.isEdge0Installed() else { throw PointVerseError.modelNotInstalled }
            let modelURL = await registry.edge0Directory()
            try loadEdge0Engine(modelURL: modelURL)
            return nil
        }
        guard let preferred = ModelSelection.selectedLanguageModel() else { throw PointVerseError.modelNotInstalled }
        guard let resolved = await registry.resolveInstalledModel(preferred: preferred, candidates: ModelSelection.languageModels) else {
            PointVerseLog.transcription.error("No installed language model found; preferred=\(preferred.id, privacy: .public)")
            throw PointVerseError.modelNotInstalled
        }
        if resolved.id != preferred.id {
            UserDefaults.standard.set(resolved.id, forKey: ModelSelection.languageDefaultsKey)
            PointVerseLog.transcription.notice("Preferred model unavailable; selected installed fallback=\(resolved.id, privacy: .public)")
        } else {
            PointVerseLog.transcription.info("Selected installed language model=\(resolved.id, privacy: .public)")
        }
        let modelURL = await registry.installedURL(for: resolved)
        try loadEngine(modelURL: modelURL)
        return resolved
    }

    private static func formattedConversation(_ messages: [ConversationMessage]) -> String {
        guard !messages.isEmpty else { return "No follow-up discussion yet." }
        return messages.suffix(4).map {
            ($0.role == "assistant" ? "Assistant: " : "User: ") + String($0.text.prefix(250))
        }.joined(separator: "\n")
    }

    private static func assistantPreamble(for manifest: ModelManifest) -> String {
        // Qwen3 text models support the explicit non-thinking prefix. The
        // Qwen3-VL Instruct chat template does not; injecting it can make the
        // model treat the assistant turn as already completed and emit EOG.
        manifest.id == ModelManifest.qwen3VL2BQ8.id ? "" : "<think>\n\n</think>\n"
    }

    private static func cleanReply(_ value: String) -> String {
        var reply = value.components(separatedBy: "<|im_end|>").first ?? value
        reply = reply
            .replacingOccurrences(of: "<|im_start|>", with: "")
            .replacingOccurrences(of: "<think>", with: "")
            .replacingOccurrences(of: "</think>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        reply = reply.replacingOccurrences(
            of: "^(assistant|user)\\b\\s*:?\\s*",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        return reply.trimmingCharacters(in: .whitespacesAndNewlines)
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

    func complete(prompt: String, maximumTokens: Int, stopAtNewline: Bool = true) throws -> String {
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
            if result.contains("<|im_end|>") || (stopAtNewline && result.contains("\n")) { break }
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
