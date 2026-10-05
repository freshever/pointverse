import Foundation
import CoreML
import CryptoKit
import PointVerseKit
import QwenAdapter

@MainActor
final class AppContainer: ObservableObject {
    let database: PointDatabase
    let blobStore: AudioBlobStore
    let imageBlobStore: ImageBlobStore
    let captureUseCase: CaptureUseCase
    let transcriptionService: TranscriptionService
    let speechModelManagers: [ModelDownloadManager]
    let languageModelManagers: [ModelDownloadManager]
    let imageModelManagers: [ModelDownloadManager]
    let visionModelManagers: [ModelDownloadManager]
    let embeddingModelManagers: [ModelDownloadManager]
    let imageGenerator: LocalImageGenerator
    let visionGenerator: QwenVisionGenerator
    let promptTranslator: QwenTitleGenerator
    private(set) var embeddingService: EmbeddingService?
    private let modelRegistry: ModelRegistry
    private let applicationSupportRoot: URL
    let imageTextRecognizer = ImageTextRecognizer()
    @Published private(set) var startupError: String?
    @Published private(set) var embeddingStartupError: String?

    init() {
        do {
            let root = try AudioBlobStore.applicationSupportRoot()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let database = try PointDatabase(path: root.appending(path: "pointverse.sqlite").path)
            let blobStore = AudioBlobStore(rootURL: root)
            let modelRegistry = ModelRegistry(rootURL: root)
            self.modelRegistry = modelRegistry
            self.applicationSupportRoot = root
            let modelExecutionGate = ModelExecutionGate()
            let qwenGenerator = QwenTitleGenerator(registry: modelRegistry, executionGate: modelExecutionGate)
            self.database = database
            self.blobStore = blobStore
            self.imageBlobStore = ImageBlobStore(rootURL: root)
            self.captureUseCase = CaptureUseCase(
                recorder: SystemAudioRecorder(),
                blobStore: blobStore,
                repository: database
            )
            self.promptTranslator = qwenGenerator
            self.visionGenerator = QwenVisionGenerator(registry: modelRegistry, executionGate: modelExecutionGate)
            self.transcriptionService = TranscriptionService(
                repository: database,
                blobStore: blobStore,
                recognizer: OnDeviceSpeechRecognizer(),
                titleGenerator: qwenGenerator
            )
            self.imageGenerator = LocalImageGenerator(registry: modelRegistry, rootURL: root, executionGate: modelExecutionGate)
            self.speechModelManagers = ModelSelection.speechModels.map { ModelDownloadManager(registry: modelRegistry, manifest: $0) }
            self.languageModelManagers = ModelSelection.languageModels.map { ModelDownloadManager(registry: modelRegistry, manifest: $0) }
            self.imageModelManagers = ModelSelection.imageModels.map { ModelDownloadManager(registry: modelRegistry, manifest: $0) }
            self.visionModelManagers = ModelSelection.visionModels.map { ModelDownloadManager(registry: modelRegistry, manifest: $0) }
            self.embeddingModelManagers = ModelSelection.embeddingModels.map { ModelDownloadManager(registry: modelRegistry, manifest: $0) }
            self.embeddingService = nil
        } catch {
            fatalError("PointVerse storage could not be initialized: \(error)")
        }
    }

    func deletePoint(_ id: PointID) async throws {
        let imagePaths = try await database.images(pointID: id).map(\.relativePath)
        let path = try await database.deletePoint(id: id)
        if let path { try await blobStore.delete(relativePath: path) }
        for imagePath in imagePaths { try? await imageBlobStore.delete(relativePath: imagePath) }
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
            embeddingService = EmbeddingService(repository: database, provider: provider)
            embeddingStartupError = nil
            PointVerseLog.embedding.info("E5 embedding service is ready")
        } catch {
            embeddingStartupError = "E5 模型加载失败：\(error.localizedDescription)"
            PointVerseLog.embedding.error("E5 model load failed: \(String(describing: error), privacy: .public)")
        }
    }

    func removeEmbeddingArtifacts() {
        embeddingService = nil
        try? FileManager.default.removeItem(at: embeddingCompiledURL)
        try? FileManager.default.removeItem(at: embeddingPackageURL)
        embeddingStartupError = "请先在本地模型中下载语义分类模型"
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
