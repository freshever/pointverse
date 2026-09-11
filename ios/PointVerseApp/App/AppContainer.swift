import Foundation
import PointVerseKit
import QwenAdapter

@MainActor
final class AppContainer: ObservableObject {
    let database: PointDatabase
    let blobStore: AudioBlobStore
    let captureUseCase: CaptureUseCase
    let transcriptionService: TranscriptionService
    let modelDownloadManager: ModelDownloadManager
    let qwenDownloadManager: ModelDownloadManager
    @Published private(set) var startupError: String?

    init() {
        do {
            let root = try AudioBlobStore.applicationSupportRoot()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let database = try PointDatabase(path: root.appending(path: "pointverse.sqlite").path)
            let blobStore = AudioBlobStore(rootURL: root)
            let modelRegistry = ModelRegistry(rootURL: root)
            self.database = database
            self.blobStore = blobStore
            self.captureUseCase = CaptureUseCase(
                recorder: SystemAudioRecorder(),
                blobStore: blobStore,
                repository: database
            )
            self.transcriptionService = TranscriptionService(
                repository: database,
                blobStore: blobStore,
                recognizer: HybridSpeechRecognizer(registry: modelRegistry),
                titleGenerator: QwenTitleGenerator(registry: modelRegistry)
            )
            self.modelDownloadManager = ModelDownloadManager(registry: modelRegistry, manifest: .whisperBaseQ5)
            self.qwenDownloadManager = ModelDownloadManager(registry: modelRegistry, manifest: .qwen3_0_6BQ8)
        } catch {
            fatalError("PointVerse storage could not be initialized: \(error)")
        }
    }

    func prepare() async {
        do {
            try await database.migrate()
            await transcriptionService.resumePending()
            await transcriptionService.deriveMissingTitles()
        } catch {
            startupError = "本地资料库初始化失败"
        }
    }
}
