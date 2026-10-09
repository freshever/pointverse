import Foundation
import PointVerseKit

@MainActor
final class Edge0DownloadManager: NSObject, ObservableObject {
    enum State: Equatable {
        case checking, notInstalled, downloading(Double), verifying, installed, failed(PointVerseError)
    }

    @Published private(set) var state: State = .checking
    private nonisolated let registry: ModelRegistry
    private var session: URLSession!
    private var task: URLSessionDownloadTask?
    private var componentIndex = 0

    init(registry: ModelRegistry) {
        self.registry = registry
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: "com.pointverse.poc.model-download.edge0-8b")
        configuration.sessionSendsLaunchEvents = true
        configuration.waitsForConnectivity = true
        configuration.isDiscretionary = false
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        restoreBackgroundTask()
    }

    func refresh() async {
        state = await registry.isEdge0Installed() ? .installed : .notInstalled
    }

    func download() {
        guard task == nil else { return }
        state = .downloading(0)
        Task {
            do {
                _ = try await registry.prepareEdge0Download()
                componentIndex = await firstMissingComponentIndex()
                startCurrentComponent()
            } catch let error as PointVerseError {
                state = .failed(error)
            } catch {
                state = .failed(.modelNotInstalled)
            }
        }
    }

    func cancel() {
        let active = task
        task = nil
        active?.cancel { data in
            Task { @MainActor in
                if let data { try? data.write(to: self.resumeURL, options: .atomic) }
                self.state = .notInstalled
            }
        }
    }

    func remove() {
        task?.cancel()
        task = nil
        Task {
            do {
                try await registry.removeEdge0()
                state = .notInstalled
            } catch {
                state = .failed(.modelNotInstalled)
            }
        }
    }

    private var current: Edge0ModelComponent { Edge0Model8B.components[componentIndex] }
    private var resumeURL: URL {
        registry.modelsDirectory.appending(path: Edge0Model8B.folderName + ".\(current.filename).resume")
    }

    private func firstMissingComponentIndex() async -> Int {
        let root = await registry.edge0Directory()
        for (index, component) in Edge0Model8B.components.enumerated() {
            let url = root.appending(path: component.filename)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            if size != component.byteCount { return index }
        }
        return Edge0Model8B.components.count
    }

    private func startCurrentComponent() {
        guard componentIndex < Edge0Model8B.components.count else {
            task = nil
            state = .installed
            return
        }
        let next: URLSessionDownloadTask
        if let resumeData = try? Data(contentsOf: resumeURL), !resumeData.isEmpty {
            next = session.downloadTask(withResumeData: resumeData)
        } else {
            next = session.downloadTask(with: current.downloadURL)
        }
        next.taskDescription = current.filename
        next.countOfBytesClientExpectsToReceive = current.byteCount
        task = next
        next.resume()
    }

    private func completedBytes(before index: Int) -> Int64 {
        Edge0Model8B.components.prefix(index).reduce(0) { $0 + $1.byteCount }
    }

    private func restoreBackgroundTask() {
        session.getAllTasks { tasks in
            Task { @MainActor in
                guard let active = tasks.compactMap({ $0 as? URLSessionDownloadTask }).first,
                      let filename = active.taskDescription,
                      let index = Edge0Model8B.components.firstIndex(where: { $0.filename == filename }) else {
                    await self.refresh()
                    return
                }
                self.componentIndex = index
                self.task = active
                let downloaded = self.completedBytes(before: index) + active.countOfBytesReceived
                self.state = .downloading(min(1, Double(downloaded) / Double(Edge0Model8B.totalByteCount)))
            }
        }
    }
}

extension Edge0DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in
            let downloaded = self.completedBytes(before: self.componentIndex) + totalBytesWritten
            self.state = .downloading(min(1, Double(downloaded) / Double(Edge0Model8B.totalByteCount)))
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let staging = registry.modelsDirectory.appending(path: "edge0-component.download")
        do {
            try FileManager.default.createDirectory(at: registry.modelsDirectory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: staging.path) { try FileManager.default.removeItem(at: staging) }
            try FileManager.default.moveItem(at: location, to: staging)
        } catch {
            Task { @MainActor in
                self.task = nil
                self.state = .failed(.modelNotInstalled)
            }
            return
        }
        Task { @MainActor in
            do {
                self.state = .verifying
                let component = self.current
                try await self.registry.installEdge0Component(component, downloadedURL: staging)
                try? FileManager.default.removeItem(at: self.resumeURL)
                self.componentIndex += 1
                self.state = .downloading(Double(self.completedBytes(before: self.componentIndex)) / Double(Edge0Model8B.totalByteCount))
                self.startCurrentComponent()
            } catch let error as PointVerseError {
                self.task = nil
                self.state = .failed(error)
            } catch {
                self.task = nil
                self.state = .failed(.modelNotInstalled)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error else { return }
        let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        Task { @MainActor in
            guard self.task != nil else { return }
            self.task = nil
            if let data { try? data.write(to: self.resumeURL, options: .atomic) }
            self.state = .failed(.modelNotInstalled)
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        Task { @MainActor in BackgroundSessionEvents.shared.finish(identifier: identifier) }
    }
}
