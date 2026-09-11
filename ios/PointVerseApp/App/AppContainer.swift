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
    let speechModelManagers: [ModelDownloadManager]
    let languageModelManagers: [ModelDownloadManager]
    let conversationService: ConversationService
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
            let qwenGenerator = QwenTitleGenerator(registry: modelRegistry)
            self.transcriptionService = TranscriptionService(
                repository: database,
                blobStore: blobStore,
                recognizer: HybridSpeechRecognizer(registry: modelRegistry),
                titleGenerator: qwenGenerator
            )
            self.conversationService = ConversationService(repository: database, generator: qwenGenerator)
            let speechManagers = ModelSelection.speechModels.map { ModelDownloadManager(registry: modelRegistry, manifest: $0) }
            let languageManagers = ModelSelection.languageModels.map { ModelDownloadManager(registry: modelRegistry, manifest: $0) }
            self.speechModelManagers = speechManagers
            self.languageModelManagers = languageManagers
            self.modelDownloadManager = speechManagers.first(where: { $0.manifest == .whisperBaseQ5 })!
            self.qwenDownloadManager = languageManagers[0]
        } catch {
            fatalError("PointVerse storage could not be initialized: \(error)")
        }
    }

    func deletePoint(_ id: PointID) async throws {
        let path = try await database.deletePoint(id: id)
        try await blobStore.delete(relativePath: path)
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
