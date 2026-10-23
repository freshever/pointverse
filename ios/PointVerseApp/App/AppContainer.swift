import Foundation
import CoreML
import CryptoKit
import PointVerseKit
import QwenAdapter
import WhisperAdapter

enum AppStorageMode: Equatable {
    case production
    case test
}

@MainActor
final class AppContainer: ObservableObject {
    static let enterTestMode = Notification.Name("PointVerseEnterTestMode")
    static let testDataDidChange = Notification.Name("PointVerseTestDataDidChange")
    let storageMode: AppStorageMode
    let database: PointDatabase
    let blobStore: AudioBlobStore
    let imageBlobStore: ImageBlobStore
    let captureUseCase: CaptureUseCase
    let transcriptionService: TranscriptionService
    let audioUnderstandingService: AudioUnderstandingService
    let recordingModelManager: RecordingModelManager
    let conversationService: ConversationService
    let speechModelManagers: [ModelDownloadManager]
    let languageModelManagers: [ModelDownloadManager]
    let edge0ModelManager: Edge0DownloadManager
    let imageModelManagers: [ModelDownloadManager]
    let visionModelManagers: [ModelDownloadManager]
    let embeddingModelManagers: [ModelDownloadManager]
    let audioUnderstandingModelManagers: [ModelDownloadManager]
    let imageGenerator: LocalImageGenerator
    let imageGenerationWorkflow: ImageGenerationWorkflow
    let visionGenerator: QwenVisionGenerator
    let promptTranslator: QwenTitleGenerator
    private(set) var embeddingService: EmbeddingService?
    private var embeddingProvider: (any PointEmbedding)?
    private let lccSemanticIndex = LCCSemanticIndex()
    private let modelRegistry: ModelRegistry
    private let modelExecutionGate: ModelExecutionGate
    private let applicationSupportRoot: URL
    let imageTextRecognizer = ImageTextRecognizer()
    @Published private(set) var startupError: String?
    @Published private(set) var embeddingStartupError: String?
    @Published private(set) var memoryTestGenerationStatus = ""

    init(storageMode: AppStorageMode = .production) {
        self.storageMode = storageMode
        do {
            let sharedRoot = try AudioBlobStore.applicationSupportRoot()
            let dataRoot = storageMode == .test
                ? sharedRoot.appending(path: "test-mode", directoryHint: .isDirectory)
                : sharedRoot
            try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
            let databaseName = storageMode == .test ? "pointverse-test.sqlite" : "pointverse.sqlite"
            let database = try PointDatabase(path: dataRoot.appending(path: databaseName).path)
            let blobStore = AudioBlobStore(rootURL: dataRoot)
            // Downloaded models are read-only runtime assets and are shared by
            // both modes; user content and SQLite files remain fully isolated.
            let modelRegistry = ModelRegistry(rootURL: sharedRoot)
            self.modelRegistry = modelRegistry
            self.applicationSupportRoot = sharedRoot
            let modelExecutionGate = ModelExecutionGate.shared
            self.modelExecutionGate = modelExecutionGate
            self.recordingModelManager = RecordingModelManager.shared(rootURL: sharedRoot, executionGate: modelExecutionGate)
            let qwenGenerator = QwenTitleGenerator(registry: modelRegistry, executionGate: modelExecutionGate)
            self.database = database
            self.blobStore = blobStore
            self.imageBlobStore = ImageBlobStore(rootURL: dataRoot)
            self.captureUseCase = CaptureUseCase(
                recorder: SystemAudioRecorder(),
                blobStore: blobStore,
                repository: database
            )
            self.promptTranslator = qwenGenerator
            self.visionGenerator = QwenVisionGenerator(registry: modelRegistry, executionGate: modelExecutionGate)
            let whisperRecognizer = WhisperRecognizer(registry: modelRegistry, executionGate: modelExecutionGate)
            self.transcriptionService = TranscriptionService(
                repository: database,
                blobStore: blobStore,
                recognizer: OnDeviceSpeechRecognizer(),
                whisperRecognizer: whisperRecognizer,
                titleGenerator: qwenGenerator
            )
            self.audioUnderstandingService = AudioUnderstandingService(
                repository: database, blobStore: blobStore, transcriptionService: self.transcriptionService,
                registry: modelRegistry, rootURL: sharedRoot, executionGate: modelExecutionGate
            )
            self.conversationService = ConversationService(repository: database, generator: qwenGenerator)
            let imageGenerator = LocalImageGenerator(registry: modelRegistry, rootURL: sharedRoot, executionGate: modelExecutionGate)
            self.imageGenerator = imageGenerator
            self.imageGenerationWorkflow = ImageGenerationWorkflow(
                promptTranslator: qwenGenerator,
                imageGenerator: imageGenerator
            )
            self.speechModelManagers = ModelSelection.speechModels.map { ModelDownloadManager(registry: modelRegistry, manifest: $0) }
            self.languageModelManagers = ModelSelection.languageModels.map { ModelDownloadManager(registry: modelRegistry, manifest: $0) }
            self.edge0ModelManager = Edge0DownloadManager(registry: modelRegistry)
            self.imageModelManagers = ModelSelection.imageModels.map { ModelDownloadManager(registry: modelRegistry, manifest: $0) }
            self.visionModelManagers = ModelSelection.visionModels.map { ModelDownloadManager(registry: modelRegistry, manifest: $0) }
            self.embeddingModelManagers = ModelSelection.embeddingModels.map { ModelDownloadManager(registry: modelRegistry, manifest: $0) }
            self.audioUnderstandingModelManagers = ModelSelection.audioUnderstandingModels.map { ModelDownloadManager(registry: modelRegistry, manifest: $0) }
            self.embeddingService = nil
        } catch {
            fatalError("PointVerse storage could not be initialized: \(error)")
        }
    }

    func configurePointVerseCloud(baseURL: URL?, accessToken: String?) async {
        await promptTranslator.configurePointVerseCloud(baseURL: baseURL, accessToken: accessToken)
    }

    func analyzeLCC(_ entry: PointMapEntry, useJudge: Bool, persist: Bool = true,
                    progress: @escaping @MainActor @Sendable (String) -> Void) async throws -> LCCClassificationReview {
        if useJudge {
            await progress("提取内容主题…")
            var modelID: String?
            var theme: PointThemeClassifier.Result?
            let decision: LCCClassificationDecision
            do {
                let reply = try await promptTranslator.extractPointTheme(entry: entry)
                try Task.checkCancellation()
                modelID = reply.modelID
                let parsed: PointThemeClassifier.Result
                do { parsed = try PointThemeClassifier.parse(reply.text); theme = parsed }
                catch { throw PointVerseError.invalidModelOutput }
                if let id = parsed.domainID {
                    decision = .init(status: .suggested, ids: [id], reason: "识别主题为“\(parsed.theme)”，程序已匹配到此目录，可随时修改。")
                } else {
                    decision = .init(status: .themeOnly, ids: [], reason: "主题已保存，可在“主题”中浏览；暂未匹配标准目录，不强行归类。")
                }
            } catch {
                if error is CancellationError { throw error }
                try Task.checkCancellation()
                decision = .init(status: .failed, ids: [], reason: modelID == nil
                    ? "主题模型调用失败：\(String(error.localizedDescription.prefix(200)))"
                    : "模型未返回简短主题（可能回显原文或含多余内容），请重试。")
            }
            try Task.checkCancellation()
            let review = LCCClassificationReview(entry: entry, embeddingModelID: "未使用（中文主题提取）",
                judgeModelID: modelID, candidates: [], decision: decision,
                theme: theme?.theme, rawTheme: theme?.rawTheme, mappingVersion: PointThemeClassifier.mappingVersion)
            if persist { try await database.saveLCCClassificationReview(review) }
            return review
        }
        guard let provider = embeddingProvider else {
            throw LCCAnalysisError.embeddingUnavailable
        }
        guard LCCCatalog.snapshot != nil else { throw PointVerseError.invalidModelOutput }
        let candidates = try await lccSemanticIndex.retrieve(entry: entry, provider: provider,
                                                            gate: modelExecutionGate, progress: progress)
        try Task.checkCancellation()
        guard !candidates.isEmpty else { throw PointVerseError.invalidModelOutput }
        let decision = LCCClassificationDecision(status: .retrievalOnly, ids: [], reason: "仅按语义检索得到候选，尚未由模型判断。召回分数不是归类正确率。")
        try Task.checkCancellation()
        let review = LCCClassificationReview(entry: entry, embeddingModelID: provider.modelID,
                                             judgeModelID: nil, candidates: candidates, decision: decision)
        if persist { try await database.saveLCCClassificationReview(review) }
        return review
    }

    func installedSpeechModelIDs() async -> [String] {
        var result = ["apple-speech-on-device"]
        for manifest in ModelSelection.speechModels where await modelRegistry.isInstalled(manifest) {
            result.append(manifest.id)
        }
        return result
    }

    func deletePoint(_ id: PointID) async throws {
        try await database.moveToTrash([.init(pointID: id, reason: "用户手动移入回收站")])
    }

    func restorePoints(_ ids: [PointID]) async throws {
        try await database.restoreFromTrash(ids)
        refreshEmbeddings()
        Task { await transcriptionService.resumePending() }
    }

    func refreshEmbeddings() {
        guard let embeddingService else {
            PointVerseLog.embedding.notice("Embedding refresh skipped because the service is not ready")
            return
        }
        PointVerseLog.embedding.info("Embedding refresh requested")
        Task { await embeddingService.resumePending() }
    }

    func prepare() async {
        do {
            PointVerseLog.embedding.info("App preparation started")
            try await database.migrate()
            // Semantic indexing must not wait behind optional, potentially slow
            // Qwen title generation.
            await prepareEmbeddingService()
            await embeddingService?.resumePending()
            await transcriptionService.resumePending()
            await embeddingService?.resumePending()
            Task { await transcriptionService.deriveMissingTitles() }
            PointVerseLog.embedding.info("App preparation completed")
        } catch {
            startupError = "本地资料库初始化失败"
            PointVerseLog.embedding.error("App preparation failed: \(String(describing: error), privacy: .public)")
        }
    }

    func startWatchConnectivity() {
        PhoneWatchTransferReceiver.shared.configure(
            database: database,
            blobStore: blobStore,
            transcriptionService: transcriptionService
        )
    }

    func prepareEmbeddingService() async {
        guard let tokenizerJSON = Bundle.main.url(forResource: "tokenizer", withExtension: "json") else {
            embeddingStartupError = "App 中缺少 multilingual-e5-small tokenizer"
            PointVerseLog.embedding.error("E5 tokenizer resource is missing")
            return
        }
        let compiledURL = embeddingCompiledURL
        if !FileManager.default.fileExists(atPath: compiledURL.path) {
            guard await modelRegistry.isInstalled(.harkMultilingualE5Small) else {
                embeddingService = nil
                embeddingStartupError = "请先在本地模型中下载语义分类模型"
                PointVerseLog.embedding.notice("Hark E5 is not installed")
                return
            }
            do {
                try await installHarkEmbeddingModel()
            } catch {
                embeddingStartupError = "E5 模型安装失败：\(error.localizedDescription)"
                PointVerseLog.embedding.error("E5 model installation failed: \(String(describing: error), privacy: .public)")
                return
            }
        }
        do {
            PointVerseLog.embedding.info("Loading downloaded Hark E5 model and bundled tokenizer")
            let provider = try await E5CoreMLEmbedding.load(modelURL: compiledURL, tokenizerFolder: tokenizerJSON.deletingLastPathComponent())
            embeddingProvider = provider
            embeddingService = EmbeddingService(repository: database, provider: provider, executionGate: modelExecutionGate)
            embeddingStartupError = nil
            PointVerseLog.embedding.info("E5 embedding service is ready")
        } catch {
            embeddingStartupError = "E5 模型加载失败：\(error.localizedDescription)"
            PointVerseLog.embedding.error("E5 model load failed: \(String(describing: error), privacy: .public)")
        }
    }

    func removeEmbeddingArtifacts() {
        embeddingService = nil
        embeddingProvider = nil
        try? FileManager.default.removeItem(at: embeddingCompiledURL)
        try? FileManager.default.removeItem(at: embeddingPackageURL)
        embeddingStartupError = "请先在本地模型中下载语义分类模型"
    }

    func makeTestModeDatabase() async throws -> PointDatabase {
        let directory = applicationSupportRoot.appending(path: "test-mode", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excludedDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excludedDirectory.setResourceValues(values)
        let database = try PointDatabase(path: directory.appending(path: "pointverse-test.sqlite").path)
        try await database.migrate()
        return database
    }

    func refreshTestModeEmbeddings(in database: PointDatabase) async -> Bool {
        guard let embeddingProvider else { return false }
        let service = EmbeddingService(repository: database, provider: embeddingProvider, executionGate: modelExecutionGate)
        await service.resumePending()
        return true
    }

    func appendGeneratedTestTexts(count: Int = 100) async throws -> Int {
        guard storageMode == .test else { return 0 }
        let existing = try await database.listPoints(matching: "").count
        let texts: [String]
        do {
            texts = try await promptTranslator.generateTestTexts(count: count, startingAt: existing)
            PointVerseLog.storage.info("Local language model generated \(texts.count, privacy: .public) test texts")
        } catch {
            // Test mode must remain usable before a language model is
            // installed, or when a small model emits malformed JSON.
            texts = TestTextFactory.make(count: count, startingAt: existing)
            PointVerseLog.storage.notice("Falling back to deterministic test corpus: \(String(describing: error), privacy: .public)")
        }
        for text in texts {
            _ = try await database.commitTextPoint(text: text)
        }
        await embeddingService?.resumePending()
        let total = try await database.listPoints(matching: "").count
        NotificationCenter.default.post(name: Self.testDataDidChange, object: total)
        return total
    }

    /// Reproducible UI fixtures. Vectors and province coordinates are synthetic,
    /// so this dataset tests the memory flow without downloading any model.
    func appendMemoryTestTexts() async throws -> Int {
        guard storageMode == .test else { return 0 }
        let stories: [[String]] = [
            [
                "我想做一个完全离线的笔记工具，本地模型可以保护私人想法。",
                "本地模型做语音转文字很方便，但我需要看看手机的内存限制。",
                "本地模型生成图片时内存占用太高，不能同时加载多个模型。",
                "本地模型应该按需加载，用完释放内存，而不是全部常驻。",
                "如果本地模型无法完成任务，可以让用户主动选择网络模型。",
                "文本、图片和语义理解应该分别选择模型，不能共用一个默认模型。",
                "本地模型优先，网络模型需要明确授权，记录也要保存实际模型来源。",
                "现在我想重新整理本地模型方案：隐私、内存和使用体验怎样平衡？"
            ],
            [
                "我想养成跑步习惯，先每周跑三次，不追求速度。",
                "跑步第二周，我发现跑得太快很容易累，应该先控制心率。",
                "跑步时膝盖有些不舒服，我需要降低训练量并观察身体反应。",
                "我把跑步改为跑走结合，恢复比强行完成里程更重要。",
                "跑步安排要和睡眠一起考虑，熬夜后不要追求训练成绩。",
                "最近跑步比以前轻松了，稳定的节奏比一次跑很远更有效。",
                "我想用跑步记录观察自己的变化，而不是只看配速数字。",
                "现在回看跑步计划，我更在意坚持和恢复，下一阶段怎么安排？"
            ],
            [
                "我想写一个关于未来城市的小说，先从一个普通居民开始。",
                "小说里未来城市技术很先进，但主人公仍然感到孤独。",
                "我在想小说人物的动机：他为什么想离开这座未来城市？",
                "小说可以加入旧街区，让未来城市也保留过去的生活痕迹。",
                "主人公可能不是想逃离城市，而是想找回人与人的联系。",
                "小说的冲突应该通过具体事件展现，少一些直接解释世界观。",
                "我试写了主人公回到旧街区的一幕，城市与记忆的联系更清楚了。",
                "现在想整理未来城市小说：从技术设定走向人物关系，接下来写哪一幕？"
            ]
        ]
        let batch = UUID().uuidString
        let now = Date()
        var generatedThemes = 0
        for (theme, story) in stories.enumerated() {
            let themeName = ["本地模型的隐私与内存", "跑步习惯与恢复", "未来城市小说创作"][theme]
            let generated = try? await promptTranslator.generateMemoryTestStory(theme: themeName)
            if generated != nil { generatedThemes += 1 }
            let texts = generated?.texts ?? story
            for (index, text) in texts.enumerated() {
                let date = now.addingTimeInterval(-Double(49 - index * 7) * 86400)
                let id = try await database.commitTextPoint(text: text, createdAt: date)
                if let modelID = generated?.modelID {
                    try await database.markTestTextProvenance(pointID: id, modelID: modelID)
                }
                var vector = [Float](repeating: 0, count: 384)
                vector[theme] = 1
                vector[3 + index] = 0.025
                try await database.saveEmbedding(.init(pointID: id, revision: 1,
                    modelID: EmbeddingModelIdentity.multilingualE5Small, vector: vector))
                try await database.saveGeographies([.init(pointID: id,
                    geographyVersion: GeographyIdentity.relativeSemanticV6, contentRevision: 1,
                    communityID: "memory-fixture:\(batch):\(theme)",
                    latitude: Double(theme * 15 - 15) + Double(index % 3) * 0.3,
                    longitude: Double(theme * 100 - 100) + Double(index / 3) * 0.3,
                    placementConfidence: 1, isPinned: true)])
            }
        }
        let total = try await database.listPoints(matching: "").count
        memoryTestGenerationStatus = "已生成24条回忆样本：\(generatedThemes)组由本地模型生成，\(3 - generatedThemes)组使用固定样本。地图使用测试向量与坐标。"
        NotificationCenter.default.post(name: Self.testDataDidChange, object: total)
        return total
    }

    func clearTestData() async throws {
        guard storageMode == .test else { throw PointVerseError.databaseCommitFailed }
        let testRoot = applicationSupportRoot.appending(path: "test-mode", directoryHint: .isDirectory)
            .standardizedFileURL.resolvingSymlinksInPath()
        let paths = try await database.clearIsolatedTestData(
            expectedURL: testRoot.appending(path: "pointverse-test.sqlite")
        )
        // Only explicit test attachments; never recursively remove a directory,
        // model downloads, or files outside the isolated test root.
        for path in paths {
            let candidate = testRoot.appending(path: path).standardizedFileURL.resolvingSymlinksInPath()
            guard candidate.path.hasPrefix(testRoot.path + "/blobs/") else { continue }
            if FileManager.default.fileExists(atPath: candidate.path) {
                try FileManager.default.removeItem(at: candidate)
            }
        }
        memoryTestGenerationStatus = ""
        NotificationCenter.default.post(name: Self.testDataDidChange, object: 0)
    }

    private var embeddingPackageURL: URL {
        applicationSupportRoot.appending(path: "embedding/HarkMultilingualE5Small.mlpackage", directoryHint: .isDirectory)
    }

    private var embeddingCompiledURL: URL {
        applicationSupportRoot.appending(path: "embedding/HarkMultilingualE5Small.mlmodelc", directoryHint: .isDirectory)
    }

    private func installHarkEmbeddingModel() async throws {
        let descriptor = try await downloadHarkModelDescriptor()
        let descriptorDigest = SHA256.hash(data: descriptor).map { String(format: "%02x", $0) }.joined()
        guard descriptorDigest == "338370ce8c5102ac1373511290d5092b28beed8ed3a2b414476e2eba2c86b397" else {
            throw PointVerseError.modelChecksumMismatch
        }
        let weightsURL = await modelRegistry.installedURL(for: .harkMultilingualE5Small)
        let packageURL = embeddingPackageURL
        let dataURL = packageURL.appending(path: "Data/com.apple.CoreML", directoryHint: .isDirectory)
        let packageWeightsURL = dataURL.appending(path: "weights/weight.bin")
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: packageURL)
        try fileManager.createDirectory(at: packageWeightsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try descriptor.write(to: dataURL.appending(path: "model.mlmodel"), options: .atomic)
        try fileManager.linkItem(at: weightsURL, to: packageWeightsURL)
        try Self.harkManifestJSON.write(to: packageURL.appending(path: "Manifest.json"), atomically: true, encoding: .utf8)

        let compiledTemporary = try await Task.detached(priority: .utility) {
            try MLModel.compileModel(at: packageURL)
        }.value
        try? fileManager.removeItem(at: embeddingCompiledURL)
        try fileManager.moveItem(at: compiledTemporary, to: embeddingCompiledURL)
    }

    private func downloadHarkModelDescriptor() async throws -> Data {
        let revision = ModelManifest.harkMultilingualE5Small.revision
        let path = "tuanda2912/hark-multilingual-e5-small-coreml/resolve/\(revision)/MultilingualE5Small.mlpackage/Data/com.apple.CoreML/model.mlmodel?download=true"
        let urls = ["https://hf-mirror.com/\(path)", "https://huggingface.co/\(path)"].compactMap(URL.init(string:))
        for url in urls {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), !data.isEmpty { return data }
            } catch {
                PointVerseLog.embedding.notice("E5 descriptor source failed: \(url.host ?? "unknown", privacy: .public)")
            }
        }
        throw PointVerseError.modelNotInstalled
    }

    private static let harkManifestJSON = """
    {"fileFormatVersion":"1.0.0","itemInfoEntries":{"7F867C29-F169-4FC7-8DF4-7756D5AA27A0":{"author":"com.apple.CoreML","description":"CoreML Model Specification","name":"model.mlmodel","path":"com.apple.CoreML/model.mlmodel"},"F4943AA6-BBAF-4CF1-9739-363CA31411C9":{"author":"com.apple.CoreML","description":"CoreML Model Weights","name":"weights","path":"com.apple.CoreML/weights"}},"rootModelIdentifier":"7F867C29-F169-4FC7-8DF4-7756D5AA27A0"}
    """
}

private enum LCCAnalysisError: LocalizedError {
    case embeddingUnavailable, busy
    var errorDescription: String? {
        switch self {
        case .embeddingUnavailable: "请先在模型页下载并启用 E5 语义模型。分类不会自动改用网络 embedding。"
        case .busy: "目录索引正在使用，请稍后重试。"
        }
    }
}

/// Contains only public directory vectors, never user Point vectors. Cached per container/session.
private actor LCCSemanticIndex {
    private var vectors: [String: [Float]] = [:]
    private var identity = ""
    private var busy = false

    func retrieve(entry: PointMapEntry, provider: any PointEmbedding, gate: ModelExecutionGate,
                  progress: @escaping @MainActor @Sendable (String) -> Void) async throws -> [LCCSemanticCandidate] {
        guard !busy else { throw LCCAnalysisError.busy }
        busy = true
        defer { busy = false }
        let key = provider.modelID + ":" + String(provider.dimension) + ":" + (LCCCatalog.snapshot?.snapshotID ?? "")
            + ":" + LCCClassificationReview.algorithmVersion
        if identity != key { vectors = [:]; identity = key }
        let terms = LCCCatalog.snapshot?.terms ?? []
        for term in terms where vectors[term.id] == nil {
            try Task.checkCancellation()
            await progress("首次准备目录语义索引 \(vectors.count)/\(terms.count)，可取消；当前会话会复用")
            vectors[term.id] = try await encode(LCCSemanticClassification.descriptor(term), provider: provider, gate: gate)
        }
        await progress("召回相关知识目录…")
        let vector = try await encode(entry.point.title + "\n" + entry.content, provider: provider, gate: gate)
        return LCCSemanticClassification.rank(query: vector, vectors: vectors)
    }

    private func encode(_ text: String, provider: any PointEmbedding, gate: ModelExecutionGate) async throws -> [Float] {
        await gate.acquire()
        do {
            try Task.checkCancellation()
            let vector = try await provider.encode(text)
            guard vector.count == provider.dimension, vector.allSatisfy(\.isFinite),
                  vector.contains(where: { $0 != 0 }) else { throw PointVerseError.invalidModelOutput }
            await gate.release()
            return vector
        } catch {
            await gate.release()
            throw error
        }
    }
}
