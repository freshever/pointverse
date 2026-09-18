import Foundation
import PointVerseKit

@MainActor
final class AppContainer: ObservableObject {
    let database: PointDatabase
    let blobStore: AudioBlobStore
    let imageBlobStore: ImageBlobStore
    let captureUseCase: CaptureUseCase
    let transcriptionService: TranscriptionService
    let embeddingService: EmbeddingService?
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
            if ProcessInfo.processInfo.isiOSAppOnMac {
                // Loading an iOS ML Program while running the iOS app directly on macOS
                // can abort inside MPSGraph deployment-target validation. This is an
                // Objective-C assertion, not a catchable Swift error.
                self.embeddingService = nil
                self.embeddingStartupError = "Mac 兼容模式暂不加载 BGE；请使用 iOS Simulator 或 iPhone"
                PointVerseLog.embedding.notice("BGE disabled for iOS-app-on-Mac compatibility mode")
            } else if let modelURL = Bundle.main.url(forResource: "BGESmallZhV15", withExtension: "mlmodelc"),
               let vocabularyURL = Bundle.main.url(forResource: "bge-small-zh-v1.5-vocab", withExtension: "txt") {
                do {
                    let provider = try BGECoreMLEmbedding(modelURL: modelURL, vocabularyURL: vocabularyURL)
                    self.embeddingService = EmbeddingService(repository: database, provider: provider)
                } catch {
                    self.embeddingService = nil
                    self.embeddingStartupError = "BGE 模型加载失败：\(error.localizedDescription)"
                    PointVerseLog.embedding.error("BGE model load failed: \(String(describing: error), privacy: .public)")
                }
            } else {
                self.embeddingService = nil
                self.embeddingStartupError = "App 中缺少 BGE 模型或词表"
            }
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
            await embeddingService?.resumePending()
        } catch {
            startupError = "本地资料库初始化失败"
        }
    }
}
