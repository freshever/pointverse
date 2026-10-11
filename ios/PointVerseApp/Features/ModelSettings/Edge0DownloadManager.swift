import Foundation
import PointVerseKit

private final class Edge0TransferState: @unchecked Sendable {
    private let lock = NSLock()
    private var taskID: Int?
    private var writer: Edge0PartialWriter?

    func set(taskID: Int, writer: Edge0PartialWriter) {
        lock.withLock { self.taskID = taskID; self.writer = writer }
    }

    func writer(for taskID: Int) -> Edge0PartialWriter? {
        lock.withLock { self.taskID == taskID ? writer : nil }
    }

    func clear(taskID: Int? = nil) {
        lock.withLock {
            guard taskID == nil || self.taskID == taskID else { return }
            self.taskID = nil
            writer = nil
        }
    }
}

private final class Edge0PartialWriter: @unchecked Sendable {
    enum ResponseError: Error { case invalidStatus(Int), invalidContentRange }

    let component: Edge0ModelComponent
    let partialURL: URL
    let requestedOffset: Int64
    private let lock = NSLock()
    private var handle: FileHandle?
    private var persistedBytes: Int64

    init(component: Edge0ModelComponent, partialURL: URL, requestedOffset: Int64) {
        self.component = component
        self.partialURL = partialURL
        self.requestedOffset = requestedOffset
        persistedBytes = requestedOffset
    }

    func prepare(for response: HTTPURLResponse) throws {
        lock.lock()
        defer { lock.unlock() }
        let shouldAppend: Bool
        switch response.statusCode {
        case 206 where requestedOffset > 0:
            let prefix = "bytes \(requestedOffset)-"
            guard response.value(forHTTPHeaderField: "Content-Range")?.lowercased().hasPrefix(prefix) == true else {
                throw ResponseError.invalidContentRange
            }
            shouldAppend = true
        case 200:
            // A CDN may discard Range while redirecting. A 200 response is the
            // whole file, so replace the partial instead of appending to it.
            shouldAppend = false
        case 206 where requestedOffset == 0:
            shouldAppend = false
        default:
            throw ResponseError.invalidStatus(response.statusCode)
        }
        try FileManager.default.createDirectory(at: partialURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: partialURL.path) {
            FileManager.default.createFile(atPath: partialURL.path, contents: nil)
        }
        let output = try FileHandle(forWritingTo: partialURL)
        if shouldAppend {
            try output.seekToEnd()
            persistedBytes = requestedOffset
        } else {
            try output.truncate(atOffset: 0)
            persistedBytes = 0
        }
        handle = output
    }

    func append(_ data: Data) throws -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { throw CocoaError(.fileWriteUnknown) }
        try handle.write(contentsOf: data)
        persistedBytes += Int64(data.count)
        return persistedBytes
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
    }
}

@MainActor
final class Edge0DownloadManager: NSObject, ObservableObject {
    enum State: Equatable {
        case checking, notInstalled, downloading(Double), verifying, installed, failed(PointVerseError)
    }

    @Published private(set) var state: State = .checking
    private nonisolated let registry: ModelRegistry
    private nonisolated let transferState = Edge0TransferState()
    private var session: URLSession!
    private var task: URLSessionDataTask?
    private var writer: Edge0PartialWriter?
    private var componentIndex = 0

    init(registry: ModelRegistry) {
        self.registry = registry
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
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

    /// Pause keeps the `.partial` file. Retry resumes from its exact byte count,
    /// including after the app has been relaunched.
    func cancel() {
        let active = task
        task = nil
        active?.cancel()
        writer?.close()
        writer = nil
        transferState.clear()
        state = .notInstalled
    }

    func remove() {
        task?.cancel()
        task = nil
        writer?.close()
        writer = nil
        transferState.clear()
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

    private func partialURL(for component: Edge0ModelComponent) -> URL {
        registry.modelsDirectory
            .appending(path: Edge0Model8B.folderName, directoryHint: .isDirectory)
            .appending(path: component.filename + ".partial")
    }

    private func fileSize(at url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }

    private func firstMissingComponentIndex() async -> Int {
        let root = await registry.edge0Directory()
        for (index, component) in Edge0Model8B.components.enumerated() {
            if fileSize(at: root.appending(path: component.filename)) != component.byteCount { return index }
        }
        return Edge0Model8B.components.count
    }

    private func startCurrentComponent() {
        guard componentIndex < Edge0Model8B.components.count else {
            task = nil
            writer = nil
            state = .installed
            return
        }
        let component = current
        let partial = partialURL(for: component)
        var offset = fileSize(at: partial)
        if offset > component.byteCount {
            try? FileManager.default.removeItem(at: partial)
            offset = 0
        }
        if offset == component.byteCount {
            verifyCurrentComponent(at: partial)
            return
        }

        var request = URLRequest(url: component.downloadURL)
        request.timeoutInterval = 120
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let sink = Edge0PartialWriter(component: component, partialURL: partial, requestedOffset: offset)
        let next = session.dataTask(with: request)
        next.taskDescription = component.filename
        next.countOfBytesClientExpectsToReceive = component.byteCount - offset
        writer = sink
        task = next
        transferState.set(taskID: next.taskIdentifier, writer: sink)
        updateProgress(componentBytes: offset)
        next.resume()
    }

    private func verifyCurrentComponent(at partial: URL) {
        task = nil
        writer?.close()
        writer = nil
        transferState.clear()
        state = .verifying
        let component = current
        Task {
            do {
                try await registry.installEdge0Component(component, downloadedURL: partial)
                componentIndex += 1
                state = .downloading(Double(completedBytes(before: componentIndex)) / Double(Edge0Model8B.totalByteCount))
                startCurrentComponent()
            } catch let error as PointVerseError {
                try? FileManager.default.removeItem(at: partial)
                state = .failed(error)
            } catch {
                try? FileManager.default.removeItem(at: partial)
                state = .failed(.modelNotInstalled)
            }
        }
    }

    private func completedBytes(before index: Int) -> Int64 {
        Edge0Model8B.components.prefix(index).reduce(0) { $0 + $1.byteCount }
    }

    private func updateProgress(componentBytes: Int64) {
        let downloaded = completedBytes(before: componentIndex) + min(componentBytes, current.byteCount)
        state = .downloading(min(1, Double(downloaded) / Double(Edge0Model8B.totalByteCount)))
    }
}

extension Edge0DownloadManager: URLSessionDataDelegate {
    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse,
              let writer = transferState.writer(for: dataTask.taskIdentifier) else {
            completionHandler(.cancel)
            return
        }
        do {
            try writer.prepare(for: response)
            completionHandler(.allow)
        } catch {
            completionHandler(.cancel)
        }
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let writer = transferState.writer(for: dataTask.taskIdentifier) else { return }
        do {
            let bytes = try writer.append(data)
            Task { @MainActor in self.updateProgress(componentBytes: bytes) }
        } catch {
            dataTask.cancel()
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let writer = transferState.writer(for: task.taskIdentifier) else {
            completionHandler(nil)
            return
        }
        var redirected = request
        if writer.requestedOffset > 0 {
            redirected.setValue("bytes=\(writer.requestedOffset)-", forHTTPHeaderField: "Range")
        }
        completionHandler(redirected)
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let completedWriter = transferState.writer(for: task.taskIdentifier)
        completedWriter?.close()
        transferState.clear(taskID: task.taskIdentifier)
        Task { @MainActor in
            guard task.taskIdentifier == self.task?.taskIdentifier else { return }
            let partial = completedWriter?.partialURL
            self.writer = nil
            self.task = nil
            if error == nil, let partial {
                self.verifyCurrentComponent(at: partial)
            } else {
                // Preserve flushed bytes on every transport error.
                self.state = .failed(.modelNotInstalled)
            }
        }
    }
}
