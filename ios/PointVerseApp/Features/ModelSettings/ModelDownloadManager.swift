import Foundation
import PointVerseKit

@MainActor
final class ModelDownloadManager: NSObject, ObservableObject {
    enum State: Equatable {
        case checking, notInstalled, downloading(Double), verifying, installed, failed(PointVerseError)
    }

    @Published private(set) var state: State = .checking {
        didSet {
            switch state {
            case .installed: finishWaiter(.success(registry.modelsDirectory.appending(path: manifest.filename)))
            case .failed(let error): finishWaiter(.failure(error))
            case .notInstalled: if completion != nil { finishWaiter(.failure(PointVerseError.cancelled)) }
            default: break
            }
        }
    }
    @Published private(set) var lastErrorDescription: String?
    private var completion: CheckedContinuation<URL, any Error>?
    private var restorationComplete = false
    private var restorationWaiters: [CheckedContinuation<Void, Never>] = []
    nonisolated let manifest: ModelManifest
    private nonisolated let registry: ModelRegistry
    private var session: URLSession!
    private var task: URLSessionDownloadTask?
    private var sourceIndex = 0
    private var attemptedResumeData = false
    private var resumedTaskID: Int?
    private var retryCounts: [Int: Int] = [:]

    init(registry: ModelRegistry, manifest: ModelManifest) {
        self.registry = registry
        self.manifest = manifest
        super.init()
        let identifier = Self.backgroundSessionPrefix + manifest.id
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.allowsCellularAccess = true
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        restoreBackgroundTask()
    }

    func refresh() async {
        guard task == nil, completion == nil else { return }
        state = await registry.isInstalled(manifest) ? .installed : .notInstalled
    }

    func download() {
        guard task == nil else { return }
        sourceIndex = 0
        attemptedResumeData = false
        resumedTaskID = nil
        retryCounts = [:]
        lastErrorDescription = nil
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

    /// Package downloads use this same background/resume/checksum engine for
    /// each component, instead of implementing a second transport layer.
    func downloadAndWait() async throws -> URL {
        if !restorationComplete {
            await withCheckedContinuation { restorationWaiters.append($0) }
        }
        if await registry.isInstalled(manifest) {
            let url = registry.modelsDirectory.appending(path: manifest.filename)
            do {
                try await registry.verifyFile(at: url, manifest: manifest)
                return url
            } catch {
                // A damaged cached component must not cause an endless loop
                // of copying the same invalid bytes into a package.
                try await registry.remove(manifest)
            }
        }
        if FileManager.default.fileExists(atPath: registry.modelsDirectory.appending(path: manifest.filename + ".partial").path),
           let installed = try? await registry.installPartial(manifest) {
            state = .installed
            return installed
        }
        return try await withCheckedThrowingContinuation { continuation in
            guard completion == nil else { continuation.resume(throwing: PointVerseError.modelLoadFailed); return }
            completion = continuation
            if task == nil { download() }
        }
    }

    private func finishWaiter(_ result: Result<URL, any Error>) {
        let pending = completion
        completion = nil
        pending?.resume(with: result)
    }

    private func startCurrentSource() {
        if !attemptedResumeData {
            attemptedResumeData = true
            let resumeURL = registry.modelsDirectory.appending(path: manifest.filename + ".resume")
            if let resumeData = try? Data(contentsOf: resumeURL), !resumeData.isEmpty {
                state = .downloading(0)
                let resumedTask = session.downloadTask(withResumeData: resumeData)
                resumedTask.taskDescription = manifest.id
                task = resumedTask
                resumedTaskID = resumedTask.taskIdentifier
                PointVerseLog.storage.info("Resuming interrupted model download")
                resumedTask.resume()
                return
            }
        }
        let sources = manifest.downloadURLs
        guard sourceIndex < sources.count else {
            task = nil
            state = .failed(.modelNotInstalled)
            return
        }
        let url = sources[sourceIndex]
        state = .downloading(0)
        let nextTask = session.downloadTask(with: url)
        nextTask.taskDescription = manifest.id
        nextTask.countOfBytesClientExpectsToReceive = manifest.displayByteCount
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
        // Keep the final source's valid resume data after retry exhaustion.
        // Only discard it when actually switching to a different source.
        clearResumeData()
        attemptedResumeData = true
        resumedTaskID = nil
        PointVerseLog.storage.info("Trying next model download source")
        startCurrentSource()
    }

    func cancel() {
        let activeTask = task
        task = nil
        activeTask?.cancel { resumeData in
            Task { @MainActor in
                if let resumeData { self.saveResumeData(resumeData) }
                self.state = .notInstalled
                PointVerseLog.storage.info("Model download paused with resume data")
            }
        }
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

private extension ModelDownloadManager {
    static var backgroundSessionPrefix: String { "com.pointverse.poc.model-download." }

    func restoreBackgroundTask() {
        session.getAllTasks { tasks in
            Task { @MainActor in
                if let active = tasks.compactMap({ $0 as? URLSessionDownloadTask })
                    .first(where: { $0.taskDescription == self.manifest.id || $0.taskDescription == nil }) {
                    self.task = active
                    if let host = active.originalRequest?.url?.host,
                       let index = self.manifest.downloadURLs.firstIndex(where: { $0.host == host }) { self.sourceIndex = index }
                    let expected = active.countOfBytesExpectedToReceive > 0
                        ? active.countOfBytesExpectedToReceive : self.manifest.displayByteCount
                    self.state = .downloading(min(1, Double(active.countOfBytesReceived) / Double(max(1, expected))))
                    PointVerseLog.storage.info("Reattached background model download")
                } else {
                    await self.refresh()
                }
                self.restorationComplete = true
                let waiters = self.restorationWaiters
                self.restorationWaiters = []
                waiters.forEach { $0.resume() }
            }
        }
    }

    func saveResumeData(_ data: Data) {
        let url = registry.modelsDirectory.appending(path: manifest.filename + ".resume")
        try? FileManager.default.createDirectory(at: registry.modelsDirectory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    func clearResumeData() {
        let url = registry.modelsDirectory.appending(path: manifest.filename + ".resume")
        try? FileManager.default.removeItem(at: url)
    }
}

extension ModelDownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : manifest.displayByteCount
        let progress = min(1, Double(totalBytesWritten) / Double(max(1, expected)))
        Task { @MainActor in
            guard self.task?.taskIdentifier == downloadTask.taskIdentifier else { return }
            self.state = .downloading(progress)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let response = downloadTask.response as? HTTPURLResponse, !(200...299).contains(response.statusCode) {
            Task { @MainActor in
                guard self.task?.taskIdentifier == downloadTask.taskIdentifier else { return }
                self.lastErrorDescription = "HTTP \(response.statusCode) · \(self.manifest.filename)"
                self.clearResumeData()
                self.retryNextSource()
            }
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
            guard self.task?.taskIdentifier == downloadTask.taskIdentifier else { return }
            do {
                state = .verifying
                _ = try await registry.installPartial(manifest)
                clearResumeData()
                task = nil
                state = .installed
            } catch let error as PointVerseError {
                lastErrorDescription = error == .modelChecksumMismatch ? "文件校验失败：\(manifest.filename)" : error.rawValue
                if error == .modelChecksumMismatch { clearResumeData(); retryNextSource() }
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
        guard let error else { return }
        let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        Task { @MainActor in
            guard self.task?.taskIdentifier == task.taskIdentifier else { return }
            self.task = nil
            self.lastErrorDescription = (error as NSError).localizedDescription
            if let resumeData, !resumeData.isEmpty {
                self.saveResumeData(resumeData)
                PointVerseLog.storage.notice("Model download interrupted; resume data saved")
            }
            let attempts = self.retryCounts[self.sourceIndex, default: 0]
            // Invalid/expired resume state must not keep retrying itself.
            if self.resumedTaskID == task.taskIdentifier && (resumeData?.isEmpty ?? true) {
                self.clearResumeData(); self.attemptedResumeData = true; self.resumedTaskID = nil
            } else if resumeData != nil {
                self.attemptedResumeData = false
            }
            if attempts < 2 {
                self.retryCounts[self.sourceIndex] = attempts + 1
                self.startCurrentSource()
            } else {
                self.retryNextSource()
            }
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        Task { @MainActor in BackgroundSessionEvents.shared.finish(identifier: identifier) }
    }
}
