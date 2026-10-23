import Foundation
import GRDB

extension PointDatabase {
    /// Capture content and its attachment references in one consistent SQLite read.
    public func cloudSnapshot(id: PointID) async throws -> CloudPointSnapshot {
        try await writer.read { db in
            let key = id.rawValue.uuidString
            guard let point = try Row.fetchOne(db, sql: "SELECT * FROM points WHERE id = ? AND trashed_at IS NULL", arguments: [key]) else { throw CloudSyncError.invalidSnapshot }
            func fetch(_ sql: String) throws -> [Row] { try Row.fetchAll(db, sql: sql, arguments: [key]) }
            let messages = try fetch("SELECT * FROM messages WHERE point_id = ? ORDER BY sequence")
            let audio = try fetch("SELECT a.* FROM audio_assets a JOIN messages m ON m.id=a.message_id WHERE m.point_id=? ORDER BY a.id")
            let images = try fetch("SELECT * FROM point_images WHERE point_id=? ORDER BY id")
            var assets: [CloudSnapshotAsset] = []
            for row in audio {
                let state: String = row["state"]
                guard state == "available" else { throw CloudSyncError.missingLocalAsset }
                assets.append(.init(id: row["id"], relativePath: row["relative_path"], sha256: row["sha256"], byteCount: row["byte_count"], kind: "audio"))
            }
            for row in images { assets.append(.init(id: row["id"], relativePath: row["relative_path"], sha256: row["sha256"], byteCount: row["byte_count"], kind: "image")) }
            guard assets.count <= 128, assets.allSatisfy({ $0.byteCount > 0 && $0.byteCount <= 128 * 1024 * 1024 }) else { throw CloudSyncError.tooLarge }
            let transcripts = try fetch("SELECT t.* FROM transcripts t JOIN audio_assets a ON a.id=t.asset_id JOIN messages m ON m.id=a.message_id WHERE m.point_id=? ORDER BY t.id")
            func jsonRows(_ rows: [Row]) -> [[String: Any]] {
                rows.map { row in
                    var values: [String: Any] = [:]
                    for (name, databaseValue) in row {
                        let value: Any
                        switch databaseValue.storage {
                        case .null: value = NSNull()
                        case .int64(let number): value = number
                        case .double(let number): value = number
                        case .string(let string): value = string
                        case .blob(let data): value = data.base64EncodedString()
                        }
                        values[name] = value
                    }
                    return values
                }
            }
            let title = try String.fetchOne(db, sql: "SELECT COALESCE(p.accepted_title,(SELECT title FROM derivations WHERE point_id=p.id AND state='succeeded' ORDER BY created_at DESC,rowid DESC LIMIT 1),'') FROM points p WHERE p.id=?", arguments: [key]) ?? ""
            let preview = String((messages.compactMap { row -> String? in row["user_text"] }.first ?? transcripts.compactMap { row -> String? in row["user_text"] ?? row["engine_text"] }.first ?? "").prefix(500))
            let revision: Int = point["head_revision"]
            let payload: [String: Any] = [
                "points": jsonRows([point]), "messages": jsonRows(messages), "audio_assets": jsonRows(audio), "point_images": jsonRows(images), "transcripts": jsonRows(transcripts),
                "transcription_candidates": jsonRows(try fetch("SELECT t.* FROM transcription_candidates t JOIN audio_assets a ON a.id=t.asset_id JOIN messages m ON m.id=a.message_id WHERE m.point_id=? ORDER BY t.id")),
                "derivations": jsonRows(try fetch("SELECT * FROM derivations WHERE point_id=? ORDER BY id")),
                "facet_overrides": jsonRows(try fetch("SELECT * FROM point_facet_overrides WHERE point_id=? ORDER BY dimension")),
                "confirmed_relations": jsonRows(try Row.fetchAll(db, sql: "SELECT * FROM confirmed_point_relations WHERE source_point_id=? OR target_point_id=? ORDER BY source_point_id,target_point_id", arguments: [key,key])),
                "origins": jsonRows(try fetch("SELECT * FROM point_origins WHERE point_id=? ORDER BY source_point_id"))
            ]
            let object: [String: Any] = ["format_version": 1, "point_id": key.lowercased(), "revision": revision, "title": title, "preview": preview, "created_at": point["created_at"] as Double,
                "assets": assets.map { ["id": $0.id, "sha256": $0.sha256.lowercased(), "byte_count": $0.byteCount, "kind": $0.kind] as [String: Any] }, "payload": payload]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            guard data.count <= 4 * 1024 * 1024 else { throw CloudSyncError.tooLarge }
            return CloudPointSnapshot(pointID: id, title: title, preview: preview, revision: revision, assets: assets, manifest: data)
        }
    }
}
