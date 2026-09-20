import Foundation
import PointVerseKit

@MainActor
final class AppContainer: ObservableObject {
    let database: PointDatabase
    let blobStore: AudioBlobStore
    let imageBlobStore: ImageBlobStore
    let captureUseCase: CaptureUseCase
    let transcriptionService: TranscriptionService
    private(set) var embeddingService: EmbeddingService?
    let imageTextRecognizer = ImageTextRecognizer()
    @Published private(set) var startupError: String?
    @Published private(set) var embeddingStartupError: String?

    init() {
        do {
            let root = try AudioBlobStore.applicationSupportRoot()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let database = try PointDatabase(path: root.appending(path: "pointverse.sqlite").path)
            let blobStore = AudioBlobStore(rootURL: root)
            self.database = database
            self.blobStore = blobStore
            self.imageBlobStore = ImageBlobStore(rootURL: root)
            self.captureUseCase = CaptureUseCase(
                recorder: SystemAudioRecorder(),
                blobStore: blobStore,
                repository: database
            )
            self.transcriptionService = TranscriptionService(
                repository: database,
                blobStore: blobStore,
                recognizer: OnDeviceSpeechRecognizer()
            )
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
        guard let embeddingService else { return }
        Task { await embeddingService.resumePending() }
    }

    func prepare() async {
        do {
            try await database.migrate()
            await transcriptionService.resumePending()
            await prepareEmbeddingService()
            await embeddingService?.resumePending()
        } catch {
            startupError = "本地资料库初始化失败"
        }
    }

    private func prepareEmbeddingService() async {
        guard !ProcessInfo.processInfo.isiOSAppOnMac else {
            embeddingStartupError = "Mac 兼容模式暂不加载 E5；请使用 iOS Simulator 或 iPhone"
            return
        }
        guard let modelURL = Bundle.main.url(forResource: "MultilingualE5Small", withExtension: "mlmodelc"),
              let tokenizerJSON = Bundle.main.url(forResource: "tokenizer", withExtension: "json") else {
            embeddingStartupError = "App 中缺少 multilingual-e5-small 模型或 tokenizer"
            return
        }
        do {
            let provider = try await E5CoreMLEmbedding.load(modelURL: modelURL, tokenizerFolder: tokenizerJSON.deletingLastPathComponent())
            embeddingService = EmbeddingService(repository: database, provider: provider)
            embeddingStartupError = nil
        } catch {
            embeddingStartupError = "E5 模型加载失败：\(error.localizedDescription)"
            PointVerseLog.embedding.error("E5 model load failed: \(String(describing: error), privacy: .public)")
        }
    }
}
