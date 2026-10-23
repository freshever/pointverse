import Foundation
import PointVerseKit
import SwiftUI

struct CloudLocalLibrary: Sendable {
    let database: PointDatabase
    let audio: AudioBlobStore
    let images: ImageBlobStore
}
struct CloudLocalCard: Identifiable {
    var id: PointID { point.id }
    let point: PointSummary
    let hash: String?
    let preview: String
    let imagePath: String?
    let hasAudio: Bool
    let error: String?
}
@MainActor
final class CloudSyncModel: ObservableObject {
    @Published private(set) var items: [CloudLocalCard] = []
    @Published private(set) var versions: [CloudPointVersion] = []
    @Published var selected: Set<PointID> = []
    @Published private(set) var failures: [PointID: String] = [:]
    @Published private(set) var loading = false
    @Published private(set) var uploading = false
    @Published private(set) var current: PointID?
    @Published private(set) var progress = 0.0
    @Published private(set) var completed = 0
    @Published private(set) var total = 0
    @Published private(set) var error: String?
    private let library: CloudLocalLibrary
    private var hashes: Set<String> = []
    private var task: Task<Void, Never>?
    private var scope = ""
    init(library: CloudLocalLibrary) { self.library = library }
    var cloudItems: [CloudPointVersion] {
        var seen = Set<String>()
        return versions.filter { seen.insert($0.pointId).inserted }
    }
    func uploaded(_ item: CloudLocalCard) -> Bool { item.hash.map { hashes.contains($0) } ?? false }
    func imageURL(_ path: String) async -> URL? { try? await library.images.url(for: path) }
    func load(account: AccountSessionStore) async {
        guard !loading, !uploading, let session = account.session else { return }
        let newScope = account.serverAddress + ":" + session.user.id
        if newScope != scope { items = []; versions = []; hashes = []; selected = []; failures = [:]; scope = newScope }
        loading = true; error = nil
        defer { loading = false }
        do {
            let points = try await library.database.listPoints(matching: "")
            var cards: [CloudLocalCard] = []
            for point in points {
                try Task.checkCancellation()
                do {
                    let snapshot = try await library.database.cloudSnapshot(id: point.id)
                    cards.append(.init(point: point, hash: snapshot.hash, preview: snapshot.preview, imagePath: snapshot.assets.first(where: { $0.kind == "image" })?.relativePath, hasAudio: snapshot.assets.contains(where: { $0.kind == "audio" }), error: nil))
                } catch {
                    cards.append(.init(point: point, hash: nil, preview: "", imagePath: nil, hasAudio: false, error: error.localizedDescription))
                }
            }
            items = cards
            selected.formIntersection(Set(cards.map(\.id)))
            versions = try await account.api().cloudVersions(token: session.accessToken)
            hashes = Set(versions.map(\.manifestHash))
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func upload(account: AccountSessionStore) {
        guard !uploading, !selected.isEmpty, let session = account.session, account.beginSync() else { return }
        let ids = items.filter { selected.contains($0.id) }.map(\.id)
        uploading = true; completed = 0; total = ids.count; progress = 0; error = nil
        task = Task {
            defer { uploading = false; current = nil; task = nil; account.endSync() }
            do {
                let api = try account.api()
                for id in ids {
                    try Task.checkCancellation()
                    current = id; progress = 0; failures[id] = nil
                    do {
                        let snapshot = try await library.database.cloudSnapshot(id: id)
                        if !hashes.contains(snapshot.hash) {
                            let bytes = max(1, snapshot.assets.reduce(Int64(snapshot.manifest.count)) { $0 + $1.byteCount })
                            var sent: Int64 = 0
                            for asset in snapshot.assets {
                                try Task.checkCancellation()
                                let file: URL
                                if asset.kind == "audio" { file = try await library.audio.url(for: asset.relativePath) }
                                else { file = try await library.images.url(for: asset.relativePath) }
                                let offset = sent
                                try await api.uploadCloudAsset(url: file, asset: asset, token: session.accessToken) { [weak self] count, _ in
                                    Task { @MainActor [weak self] in
                                        guard self?.current == id else { return }
                                        self?.progress = min(0.99, Double(offset + count) / Double(bytes))
                                    }
                                }
                                sent += asset.byteCount
                            }
                            try Task.checkCancellation()
                            let version = try await api.commitCloudPoint(snapshot, token: session.accessToken)
                            hashes.insert(snapshot.hash)
                            if !versions.contains(where: { $0.id == version.id }) { versions.insert(version, at: 0) }
                        }
                        selected.remove(id)
                    } catch {
                        if Task.isCancelled { throw CancellationError() }
                        failures[id] = error.localizedDescription
                        if case AccountAPIError.unauthorized = error { throw error }
                    }
                    completed += 1; progress = 0
                }
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
            // Re-read local content after upload so edits made during transfer stay pending.
            uploading = false; current = nil
            await load(account: account)
        }
    }
    func pause() { task?.cancel() }
}
