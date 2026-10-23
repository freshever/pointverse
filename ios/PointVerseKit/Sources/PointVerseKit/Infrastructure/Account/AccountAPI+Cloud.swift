import Foundation

extension AccountAPI {
    public func cloudVersions(token: String) async throws -> [CloudPointVersion] {
        struct Page: Decodable { let items: [CloudPointVersion]; let nextCursor: String }
        var versions: [CloudPointVersion] = []
        var cursor = ""
        repeat {
            try Task.checkCancellation()
            let data = try await request("v1/sync/points", method: "GET", token: token, query: cursor.isEmpty ? [] : [URLQueryItem(name: "cursor", value: cursor)])
            let page = try Self.decoder().decode(Page.self, from: data)
            versions.append(contentsOf: page.items)
            guard page.nextCursor != cursor || page.nextCursor.isEmpty else { throw AccountAPIError.invalidResponse }
            cursor = page.nextCursor
        } while !cursor.isEmpty
        return versions
    }
    public func uploadCloudAsset(url: URL, asset: CloudSnapshotAsset, token: String, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        guard asset.byteCount > 0, asset.byteCount <= 128 * 1024 * 1024 else { throw CloudSyncError.tooLarge }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard Int64(values.fileSize ?? 0) == asset.byteCount else { throw CloudSyncError.missingLocalAsset }
        let destination = baseURL.appendingPathComponent("v1/sync/assets/" + asset.sha256.lowercased())
        var probe = URLRequest(url: destination)
        probe.httpMethod = "HEAD"; probe.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (probeData, probeResponse) = try await session.data(for: probe)
        if (probeResponse as? HTTPURLResponse)?.statusCode == 200 { progress(asset.byteCount, asset.byteCount); return }
        if (probeResponse as? HTTPURLResponse)?.statusCode != 404 { try checkResponse(probeData, response: probeResponse, token: token) }
        var request = URLRequest(url: destination)
        request.httpMethod = "PUT"; request.timeoutInterval = 180
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(asset.byteCount), forHTTPHeaderField: "Content-Length")
        let delegate = CloudUploadProgress(progress: progress)
        let (data, response) = try await session.upload(for: request, fromFile: url, delegate: delegate)
        try checkResponse(data, response: response, token: token)
    }
    public func commitCloudPoint(_ snapshot: CloudPointSnapshot, token: String) async throws -> CloudPointVersion {
        let data = try await request("v1/sync/points", method: "POST", body: snapshot.manifest, token: token)
        let version = try Self.decoder().decode(CloudPointVersion.self, from: data)
        guard version.manifestHash == snapshot.hash, UUID(uuidString: version.pointId) == snapshot.pointID.rawValue else { throw CloudSyncError.checksum }
        return version
    }
}
private final class CloudUploadProgress: NSObject, URLSessionTaskDelegate {
    let progress: @Sendable (Int64, Int64) -> Void
    init(progress: @escaping @Sendable (Int64, Int64) -> Void) { self.progress = progress }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) { progress(totalBytesSent, totalBytesExpectedToSend) }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
