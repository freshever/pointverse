import Foundation
import PointVerseKit

@MainActor
final class ModelDownloadManager: NSObject, ObservableObject {
    enum State: Equatable {
        case checking, notInstalled, downloading(Double), verifying, installed, failed(PointVerseError)
    }

    @Published private(set) var state: State = .checking
    nonisolated let manifest = ModelManifest.whisperBaseQ5
    private nonisolated let registry: ModelRegistry
    private var session: URLSession!
    private var task: URLSessionDownloadTask?

    init(registry: ModelRegistry) {
        self.registry = registry
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        Task { await refresh() }
    }

    func refresh() async {
        state = await registry.isInstalled(manifest) ? .installed : .notInstalled
    }

    func download() {
        guard task == nil else { return }
        state = .downloading(0)
        Task {
            do {
                _ = try await registry.prepareForDownload(manifest)
                let task = session.downloadTask(with: manifest.downloadURL)
                self.task = task
                PointVerseLog.storage.info("Model download started")
                task.resume()
            } catch let error as PointVerseError {
                state = .failed(error)
            } catch {
                state = .failed(.modelNotInstalled)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = .notInstalled
        PointVerseLog.storage.info("Model download cancelled")
    }

    func remove() {
        Task {
            do {
                try await registry.remove(manifest)
                state = .notInstalled
            } catch {
                state = .failed(.modelNotInstalled)
            }
        }
    }
}

extension ModelDownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        Task { @MainActor in self.state = .downloading(progress) }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let partial = registry.modelsDirectory.appending(path: manifest.filename + ".partial")
        do {
            try FileManager.default.createDirectory(at: registry.modelsDirectory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: partial.path) { try FileManager.default.removeItem(at: partial) }
            try FileManager.default.moveItem(at: location, to: partial)
        } catch {
            Task { @MainActor in
                self.task = nil
                self.state = .failed(.modelNotInstalled)
            }
            return
        }
        Task { @MainActor in
            do {
                state = .verifying
                _ = try await registry.installPartial(manifest)
                task = nil
                state = .installed
            } catch let error as PointVerseError {
                task = nil
                state = .failed(error)
            } catch {
                task = nil
                state = .failed(.modelNotInstalled)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard error != nil else { return }
        Task { @MainActor in
            guard self.task != nil else { return }
            self.task = nil
            self.state = .failed(.modelNotInstalled)
        }
    }
}
