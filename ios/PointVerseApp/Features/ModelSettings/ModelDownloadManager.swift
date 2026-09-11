import Foundation
import PointVerseKit

@MainActor
final class ModelDownloadManager: NSObject, ObservableObject {
    enum State: Equatable {
        case checking, notInstalled, downloading(Double), verifying, installed, failed(PointVerseError)
    }

    @Published private(set) var state: State = .checking
    nonisolated let manifest: ModelManifest
    private nonisolated let registry: ModelRegistry
    private var session: URLSession!
    private var task: URLSessionDownloadTask?
    private var sourceIndex = 0

    init(registry: ModelRegistry, manifest: ModelManifest) {
        self.registry = registry
        self.manifest = manifest
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        Task { await refresh() }
    }

    func refresh() async {
        state = await registry.isInstalled(manifest) ? .installed : .notInstalled
    }

    func download() {
        guard task == nil else { return }
        sourceIndex = 0
        state = .downloading(0)
        Task {
            do {
                _ = try await registry.prepareForDownload(manifest)
                startCurrentSource()
            } catch let error as PointVerseError {
                state = .failed(error)
            } catch {
                state = .failed(.modelNotInstalled)
            }
        }
    }

    private func startCurrentSource() {
        let sources = manifest.downloadURLs
        guard sourceIndex < sources.count else {
            task = nil
            state = .failed(.modelNotInstalled)
            return
        }
        let url = sources[sourceIndex]
        state = .downloading(0)
        let nextTask = session.downloadTask(with: url)
        task = nextTask
        PointVerseLog.storage.info("Model download source started: \(url.host ?? "unknown", privacy: .public)")
        nextTask.resume()
    }

    private func retryNextSource() {
        task = nil
        sourceIndex += 1
        guard sourceIndex < manifest.downloadURLs.count else {
            PointVerseLog.storage.error("All model download sources failed")
            state = .failed(.modelNotInstalled)
            return
        }
        PointVerseLog.storage.info("Trying next model download source")
        startCurrentSource()
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = .notInstalled
        PointVerseLog.storage.info("Model download cancelled")
    }

    func remove() {
        PointVerseLog.storage.info("Model removal confirmed: \(self.manifest.id, privacy: .public)")
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
        if let response = downloadTask.response as? HTTPURLResponse, !(200...299).contains(response.statusCode) {
            Task { @MainActor in self.retryNextSource() }
            return
        }
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
                if error == .modelChecksumMismatch { retryNextSource() }
                else {
                    task = nil
                    state = .failed(error)
                }
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
            self.retryNextSource()
        }
    }
}
