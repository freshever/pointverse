import Foundation
import PointVerseKit

@MainActor
final class AppContainer: ObservableObject {
    let database: PointDatabase
    let blobStore: AudioBlobStore
    let imageBlobStore: ImageBlobStore
    let captureUseCase: CaptureUseCase
    let transcriptionService: TranscriptionService
    let imageTextRecognizer = ImageTextRecognizer()
    @Published private(set) var startupError: String?

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

    func prepare() async {
        do {
            try await database.migrate()
            await transcriptionService.resumePending()
        } catch {
            startupError = "本地资料库初始化失败"
        }
    }
}
