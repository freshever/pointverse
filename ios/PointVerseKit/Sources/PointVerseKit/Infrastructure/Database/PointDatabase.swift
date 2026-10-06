import Foundation
import GRDB

public final class PointDatabase: PointRepository, @unchecked Sendable {
    private let writer: any DatabaseWriter

    public init(path: String) throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        writer = try DatabasePool(path: path, configuration: configuration)
    }

    public init(inMemory: Bool) throws {
        writer = try DatabaseQueue()
    }

    public func migrate() async throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try Self.createV1(in: db)
        }
        migrator.registerMigration("v2-point-images") { db in
            try db.execute(sql: """
                CREATE TABLE point_images (
                    id TEXT PRIMARY KEY NOT NULL,
                    point_id TEXT NOT NULL REFERENCES points(id) ON DELETE CASCADE,
                    relative_path TEXT NOT NULL UNIQUE,
                    sha256 TEXT NOT NULL,
                    byte_count INTEGER NOT NULL,
                    recognized_text TEXT,
                    created_at REAL NOT NULL
                );
                CREATE INDEX point_images_point_id ON point_images(point_id, created_at);
                """)
        }
        migrator.registerMigration("v3-embeddings") { db in
            try db.execute(sql: Schema.v3Embeddings)
        }
        migrator.registerMigration("v4-point-geography") { db in
            try db.execute(sql: """
                CREATE TABLE point_geography (
                    point_id TEXT NOT NULL REFERENCES points(id) ON DELETE CASCADE,
                    geography_version TEXT NOT NULL,
                    content_revision INTEGER NOT NULL,
                    community_id TEXT,
                    latitude REAL NOT NULL,
                    longitude REAL NOT NULL,
                    altitude REAL NOT NULL DEFAULT 0,
                    placement_confidence REAL NOT NULL,
                    is_pinned INTEGER NOT NULL DEFAULT 0,
                    updated_at REAL NOT NULL,
                    PRIMARY KEY (point_id, geography_version)
                );
                CREATE INDEX point_geography_version
                ON point_geography(geography_version, content_revision);
                """)
        }
        migrator.registerMigration("v5-transcription-candidates") { db in
            try db.execute(sql: """
                CREATE TABLE transcription_candidates (
                    id TEXT PRIMARY KEY NOT NULL,
                    asset_id TEXT NOT NULL REFERENCES audio_assets(id) ON DELETE CASCADE,
                    model_id TEXT NOT NULL,
                    model_sha256 TEXT NOT NULL,
                    engine_text TEXT NOT NULL,
                    user_text TEXT,
                    is_selected INTEGER NOT NULL DEFAULT 0,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    UNIQUE(asset_id, model_id)
                );
                CREATE INDEX transcription_candidates_asset ON transcription_candidates(asset_id, is_selected);
                INSERT INTO transcription_candidates
                    (id, asset_id, model_id, model_sha256, engine_text, user_text, is_selected, created_at, updated_at)
                SELECT lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' ||
                       substr(lower(hex(randomblob(2))),2) || '-' ||
                       substr('89ab',abs(random()) % 4 + 1,1) || substr(lower(hex(randomblob(2))),2) || '-' ||
                       lower(hex(randomblob(6))),
                       asset_id, model_id, model_sha256, engine_text, user_text, 1, created_at, updated_at
                FROM transcripts WHERE state = 'succeeded' AND engine_text IS NOT NULL;
                """)
        }
        migrator.registerMigration("v6-audio-understanding") { db in
            try db.execute(sql: """
                CREATE TABLE audio_understanding (
                    point_id TEXT PRIMARY KEY NOT NULL REFERENCES points(id) ON DELETE CASCADE,
                    duration_seconds REAL NOT NULL,
                    loudness_db REAL NOT NULL,
                    bpm REAL,
                    dominant_pitch_hz REAL,
                    rhythm_strength REAL NOT NULL,
                    semantic_tags_json TEXT NOT NULL,
                    clap_model_id TEXT,
                    clap_vector BLOB,
                    clap_dimension INTEGER,
                    has_voice INTEGER NOT NULL DEFAULT 0,
                    updated_at REAL NOT NULL
                );
                """)
        }
        try migrator.migrate(writer)
        try await writer.write { db in
            let modelID = EmbeddingModelIdentity.multilingualE5Small
            try db.execute(sql: """
                UPDATE durable_tasks SET state = 'cancelled', updated_at = ?
                WHERE kind = 'embedding' AND state IN ('queued', 'running')
                  AND operation_id NOT LIKE '%' || ?
                """, arguments: [Date().timeIntervalSince1970, modelID])
            for row in try Row.fetchAll(db, sql: "SELECT id, head_revision, updated_at FROM points") {
                guard let uuid = UUID(uuidString: row["id"]) else { continue }
                try enqueueEmbedding(pointID: PointID(rawValue: uuid), revision: row["head_revision"],
                                     db: db, timestamp: row["updated_at"])
            }
        }
        PointVerseLog.database.info("Database migrations completed")
    }

    public func commitVoiceCapture(_ command: VoiceCaptureCommand) async throws -> PointID {
        try await writer.write { db in
            if let existing = try String.fetchOne(
                db,
                sql: "SELECT point_id FROM messages WHERE operation_id = ?",
                arguments: [command.operationID.uuidString]
            ), let uuid = UUID(uuidString: existing) {
                PointVerseLog.database.notice("Idempotent capture commit returned existing point")
                return PointID(rawValue: uuid)
            }

            let timestamp = command.createdAt.timeIntervalSince1970
            try db.execute(
                sql: "INSERT INTO points (id, created_at, updated_at) VALUES (?, ?, ?)",
                arguments: [command.pointID.rawValue.uuidString, timestamp, timestamp]
            )
            try db.execute(
                sql: "INSERT INTO messages (id, operation_id, point_id, sequence, role, modality, created_at) VALUES (?, ?, ?, 1, 'user', 'voice', ?)",
                arguments: [command.messageID.uuidString, command.operationID.uuidString, command.pointID.rawValue.uuidString, timestamp]
            )
            try db.execute(
                sql: "INSERT INTO audio_assets (id, message_id, relative_path, sha256, byte_count, duration_ms, codec, sample_rate, state, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'available', ?)",
                arguments: [command.audio.assetID.uuidString, command.messageID.uuidString, command.audio.relativePath, command.audio.sha256, command.audio.byteCount, command.audio.durationMilliseconds, command.audio.codec, command.audio.sampleRate, timestamp]
            )
            try db.execute(
                sql: "INSERT INTO transcripts (id, asset_id, locale, model_id, model_sha256, state, created_at, updated_at) VALUES (?, ?, ?, 'apple-speech-on-device', 'system', 'queued', ?, ?)",
                arguments: [UUID().uuidString, command.audio.assetID.uuidString, command.localeIdentifier, timestamp, timestamp]
            )
            let payload = "{\"pointId\":\"\(command.pointID.rawValue.uuidString)\",\"assetId\":\"\(command.audio.assetID.uuidString)\"}"
            try db.execute(
                sql: "INSERT INTO durable_tasks (id, operation_id, kind, payload_json, state, next_run_at, created_at, updated_at) VALUES (?, ?, 'transcribe', ?, 'queued', ?, ?, ?)",
                arguments: [UUID().uuidString, "transcribe:\(command.audio.assetID.uuidString)", payload, timestamp, timestamp, timestamp]
            )
            PointVerseLog.database.info("Voice capture transaction committed")
            return command.pointID
        }
    }

    public func commitTextPoint(text: String, createdAt: Date = Date()) async throws -> PointID {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw PointVerseError.databaseCommitFailed }
        return try await writer.write { db in
            let pointID = PointID()
            let messageID = UUID()
            let timestamp = createdAt.timeIntervalSince1970
            try db.execute(sql: "INSERT INTO points (id, created_at, updated_at) VALUES (?, ?, ?)",
                           arguments: [pointID.rawValue.uuidString, timestamp, timestamp])
            try db.execute(sql: """
                INSERT INTO messages (id, operation_id, point_id, sequence, role, modality, user_text, created_at)
                VALUES (?, ?, ?, 1, 'user', 'text', ?, ?)
                """, arguments: [messageID.uuidString, "text:" + messageID.uuidString, pointID.rawValue.uuidString, cleaned, timestamp])
            let title = Self.fallbackTitle(from: cleaned)
            try db.execute(sql: """
                INSERT INTO derivations (id, point_id, input_revision, model_id, model_sha256, prompt_version, title, state, adoption, created_at)
                VALUES (?, ?, 1, 'rule-title-v1', 'builtin', 'rule-title-v1', ?, 'succeeded', 'candidate', ?)
                """, arguments: [UUID().uuidString, pointID.rawValue.uuidString, title, timestamp])
            try refreshSearch(pointID: pointID, db: db)
            try enqueueEmbedding(pointID: pointID, revision: 1, db: db, timestamp: timestamp)
            return pointID
        }
    }

    public func listPoints(matching query: String) async throws -> [PointSummary] {
        try await writer.read { db in
            let rows: [Row]
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                rows = try Row.fetchAll(db, sql: """
                    SELECT p.id, COALESCE(p.accepted_title, d.title, '') AS title,
                           p.created_at, CASE WHEN m.modality = 'text' THEN 'text' ELSE t.state END AS transcript_state
                    FROM points p
                    LEFT JOIN messages m ON m.point_id = p.id AND m.sequence = 1
                    LEFT JOIN audio_assets a ON a.message_id = m.id
                    LEFT JOIN transcripts t ON t.asset_id = a.id
                    LEFT JOIN derivations d ON d.id = (SELECT id FROM derivations WHERE point_id = p.id AND state = 'succeeded' ORDER BY created_at DESC, rowid DESC LIMIT 1)
                    ORDER BY p.created_at DESC
                    """)
            } else {
                let pattern = "%" + Self.escapeLikePattern(query.trimmingCharacters(in: .whitespacesAndNewlines)) + "%"
                rows = try Row.fetchAll(db, sql: """
                    SELECT p.id, COALESCE(p.accepted_title, d.title, '') AS title,
                           p.created_at, CASE WHEN m.modality = 'text' THEN 'text' ELSE t.state END AS transcript_state
                    FROM points p
                    LEFT JOIN messages m ON m.point_id = p.id AND m.sequence = 1
                    LEFT JOIN audio_assets a ON a.message_id = m.id
                    LEFT JOIN transcripts t ON t.asset_id = a.id
                    LEFT JOIN derivations d ON d.id = (SELECT id FROM derivations WHERE point_id = p.id AND state = 'succeeded' ORDER BY created_at DESC, rowid DESC LIMIT 1)
                    WHERE COALESCE(p.accepted_title, d.title, '') LIKE ? ESCAPE '\\'
                       OR COALESCE(m.user_text, '') LIKE ? ESCAPE '\\'
                       OR COALESCE(t.user_text, t.engine_text, '') LIKE ? ESCAPE '\\'
                       OR COALESCE(d.summary, '') LIKE ? ESCAPE '\\'
                       OR COALESCE(d.tags_json, '') LIKE ? ESCAPE '\\'
                       OR EXISTS (SELECT 1 FROM point_images pi WHERE pi.point_id = p.id AND COALESCE(pi.recognized_text, '') LIKE ? ESCAPE '\\')
                    ORDER BY p.created_at DESC
                    """, arguments: [pattern, pattern, pattern, pattern, pattern, pattern])
            }
            return rows.compactMap { row in
                guard let uuid = UUID(uuidString: row["id"]) else { return nil }
                return PointSummary(
                    id: PointID(rawValue: uuid),
                    title: row["title"],
                    createdAt: Date(timeIntervalSince1970: row["created_at"]),
                    transcriptState: row["transcript_state"]
                )
            }
        }
    }

    public func pointMapEntries() async throws -> [PointMapEntry] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT p.id, COALESCE(p.accepted_title, d.title, '') AS title, p.created_at,
                       CASE WHEN m.modality = 'text' THEN 'text' ELSE t.state END AS transcript_state,
                       TRIM(
                           COALESCE(m.user_text, t.user_text, t.engine_text, '') || ' ' ||
                           COALESCE((SELECT GROUP_CONCAT(recognized_text, ' ') FROM point_images
                                     WHERE point_id = p.id AND recognized_text IS NOT NULL), '')
                       ) AS map_content,
                       COALESCE(t.locale, '') AS locale
                FROM points p
                LEFT JOIN messages m ON m.point_id = p.id AND m.sequence = 1
                LEFT JOIN audio_assets a ON a.message_id = m.id
                LEFT JOIN transcripts t ON t.asset_id = a.id
                LEFT JOIN derivations d ON d.id = (
                    SELECT id FROM derivations WHERE point_id = p.id AND state = 'succeeded'
                    ORDER BY created_at DESC, rowid DESC LIMIT 1
                )
                ORDER BY p.created_at DESC
                """).compactMap { row in
                    guard let uuid = UUID(uuidString: row["id"]) else { return nil }
                    let point = PointSummary(
                        id: PointID(rawValue: uuid), title: row["title"],
                        createdAt: Date(timeIntervalSince1970: row["created_at"]),
                        transcriptState: row["transcript_state"]
                    )
                    return PointMapEntry(point: point, content: row["map_content"], localeIdentifier: row["locale"])
                }
        }
    }

    private static func escapeLikePattern(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    public func pointDetail(id: PointID) async throws -> PointDetail {
        try await writer.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT p.id, COALESCE(p.accepted_title, d.title, '') AS title,
                       m.modality, m.user_text AS source_text,
                       a.relative_path, a.duration_ms,
                       CASE WHEN m.modality = 'text' THEN 'text' ELSE t.state END AS transcript_state,
                       t.engine_text, t.user_text, COALESCE(t.locale, '') AS locale, t.error_code, t.model_id
                FROM points p
                JOIN messages m ON m.point_id = p.id AND m.sequence = 1
                LEFT JOIN audio_assets a ON a.message_id = m.id
                LEFT JOIN transcripts t ON t.asset_id = a.id
                LEFT JOIN derivations d ON d.id = (SELECT id FROM derivations WHERE point_id = p.id AND state = 'succeeded' ORDER BY created_at DESC, rowid DESC LIMIT 1)
                WHERE p.id = ?
                """, arguments: [id.rawValue.uuidString]) else {
                throw PointVerseError.databaseCommitFailed
            }
            return PointDetail(
                id: id,
                title: row["title"],
                modality: row["modality"],
                sourceText: row["source_text"],
                audioRelativePath: row["relative_path"],
                durationMilliseconds: row["duration_ms"],
                transcriptState: row["transcript_state"],
                transcriptErrorCode: row["error_code"],
                engineText: row["engine_text"],
                userText: row["user_text"],
                localeIdentifier: row["locale"],
                transcriptModelID: row["model_id"]
            )
        }
    }

    public func queuedTranscriptionPointIDs() async throws -> [PointID] {
        try await writer.read { db in
            try String.fetchAll(db, sql: """
                SELECT m.point_id
                FROM transcripts t
                JOIN audio_assets a ON a.id = t.asset_id
                JOIN messages m ON m.id = a.message_id
                WHERE t.state IN ('queued', 'running')
                ORDER BY t.created_at
                """).compactMap(UUID.init(uuidString:)).map(PointID.init(rawValue:))
        }
    }

    public func pointIDsNeedingTitle(modelID: String) async throws -> [PointID] {
        try await writer.read { db in
            try String.fetchAll(db, sql: """
                SELECT p.id
                FROM points p
                JOIN messages m ON m.point_id = p.id AND m.sequence = 1
                JOIN audio_assets a ON a.message_id = m.id
                JOIN transcripts t ON t.asset_id = a.id AND t.state = 'succeeded'
                WHERE NOT EXISTS (
                    SELECT 1 FROM derivations d
                    WHERE d.point_id = p.id AND d.model_id = ? AND d.state = 'succeeded'
                )
                ORDER BY p.created_at
                """, arguments: [modelID])
                .compactMap(UUID.init(uuidString:))
                .map(PointID.init(rawValue:))
        }
    }

    public func markTranscriptionRunning(pointID: PointID) async throws {
        try await updateTranscript(pointID: pointID, sql: """
            UPDATE transcripts SET state = 'running', error_code = NULL, updated_at = ?
            WHERE asset_id = (SELECT a.id FROM audio_assets a JOIN messages m ON m.id = a.message_id WHERE m.point_id = ? LIMIT 1)
            """, arguments: [Date().timeIntervalSince1970, pointID.rawValue.uuidString])
    }

    public func saveTranscript(pointID: PointID, engineText: String, modelID: String, modelSHA256: String) async throws {
        try await writer.write { db in
            let timestamp = Date().timeIntervalSince1970
            try db.execute(sql: """
                UPDATE transcripts SET engine_text = ?, model_id = ?, model_sha256 = ?, state = 'succeeded', error_code = NULL, updated_at = ?
                WHERE asset_id = (SELECT a.id FROM audio_assets a JOIN messages m ON m.id = a.message_id WHERE m.point_id = ? LIMIT 1)
                """, arguments: [engineText, modelID, modelSHA256, timestamp, pointID.rawValue.uuidString])
            if let assetID = try String.fetchOne(db, sql: "SELECT a.id FROM audio_assets a JOIN messages m ON m.id = a.message_id WHERE m.point_id = ? LIMIT 1", arguments: [pointID.rawValue.uuidString]) {
                try db.execute(sql: "UPDATE transcription_candidates SET is_selected = 0 WHERE asset_id = ?", arguments: [assetID])
                try db.execute(sql: """
                    INSERT INTO transcription_candidates
                        (id, asset_id, model_id, model_sha256, engine_text, is_selected, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, 1, ?, ?)
                    ON CONFLICT(asset_id, model_id) DO UPDATE SET
                        model_sha256=excluded.model_sha256, engine_text=excluded.engine_text,
                        user_text=NULL, is_selected=1, updated_at=excluded.updated_at
                    """, arguments: [UUID().uuidString, assetID, modelID, modelSHA256, engineText, timestamp, timestamp])
            }
            let title = Self.fallbackTitle(from: engineText)
            try db.execute(sql: "DELETE FROM derivations WHERE point_id = ? AND model_id = 'rule-title-v1'", arguments: [pointID.rawValue.uuidString])
            try db.execute(sql: """
                INSERT INTO derivations (id, point_id, input_revision, model_id, model_sha256, prompt_version, title, state, adoption, created_at)
                VALUES (?, ?, 1, 'rule-title-v1', 'builtin', 'rule-title-v1', ?, 'succeeded', 'candidate', ?)
                """, arguments: [UUID().uuidString, pointID.rawValue.uuidString, title, timestamp])
            try db.execute(sql: """
                UPDATE durable_tasks SET state = 'succeeded', updated_at = ?
                WHERE operation_id = 'transcribe:' || (
                    SELECT a.id FROM audio_assets a JOIN messages m ON m.id = a.message_id WHERE m.point_id = ? LIMIT 1
                )
                """, arguments: [timestamp, pointID.rawValue.uuidString])
            try refreshSearch(pointID: pointID, db: db)
            let revision = try bumpRevision(pointID: pointID, db: db, timestamp: timestamp)
            try enqueueEmbedding(pointID: pointID, revision: revision, db: db, timestamp: timestamp)
        }
    }

    private static func fallbackTitle(from text: String) -> String {
        let cleaned = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let firstClause = cleaned.split(whereSeparator: { "。！？!?；;\n".contains($0) }).first.map(String.init) ?? cleaned
        guard firstClause.count > 20 else { return firstClause }
        return String(firstClause.prefix(20)) + "…"
    }

    public func saveCandidateTitle(pointID: PointID, title: String, modelID: String, modelSHA256: String) async throws {
        try await writer.write { db in
            let timestamp = Date().timeIntervalSince1970
            try db.execute(sql: "DELETE FROM derivations WHERE point_id = ? AND model_id = ?", arguments: [pointID.rawValue.uuidString, modelID])
            try db.execute(sql: """
                INSERT INTO derivations (id, point_id, input_revision, model_id, model_sha256, prompt_version, title, state, adoption, created_at)
                VALUES (?, ?, 1, ?, ?, 'title-v1', ?, 'succeeded', 'candidate', ?)
                """, arguments: [UUID().uuidString, pointID.rawValue.uuidString, modelID, modelSHA256, title, timestamp])
            try refreshSearch(pointID: pointID, db: db)
        }
    }

    public func conversationMessages(pointID: PointID) async throws -> [ConversationMessage] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, role, user_text, created_at FROM messages
                WHERE point_id = ? AND modality = 'text' AND user_text IS NOT NULL
                ORDER BY sequence
                """, arguments: [pointID.rawValue.uuidString]).compactMap { row in
                    guard let id = UUID(uuidString: row["id"]), let text: String = row["user_text"] else { return nil }
                    return ConversationMessage(id: id, role: row["role"], text: text, createdAt: Date(timeIntervalSince1970: row["created_at"]))
                }
        }
    }

    public func appendConversationMessage(pointID: PointID, role: String, text: String) async throws {
        guard role == "user" || role == "assistant" else { throw PointVerseError.invalidModelOutput }
        try await writer.write { db in
            let sequence = (try Int.fetchOne(db, sql: "SELECT MAX(sequence) FROM messages WHERE point_id = ?", arguments: [pointID.rawValue.uuidString]) ?? 0) + 1
            let id = UUID()
            try db.execute(sql: """
                INSERT INTO messages (id, operation_id, point_id, sequence, role, modality, user_text, created_at)
                VALUES (?, ?, ?, ?, ?, 'text', ?, ?)
                """, arguments: [id.uuidString, "text:" + id.uuidString, pointID.rawValue.uuidString, sequence, role, text, Date().timeIntervalSince1970])
            let timestamp = Date().timeIntervalSince1970
            try refreshSearch(pointID: pointID, db: db)
            let revision = try bumpRevision(pointID: pointID, db: db, timestamp: timestamp)
            try enqueueEmbedding(pointID: pointID, revision: revision, db: db, timestamp: timestamp)
        }
    }

    public func addImage(pointID: PointID, id: UUID, relativePath: String, sha256: String, byteCount: Int64, recognizedText: String?) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO point_images (id, point_id, relative_path, sha256, byte_count, recognized_text, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [id.uuidString, pointID.rawValue.uuidString, relativePath, sha256, byteCount, recognizedText, Date().timeIntervalSince1970])
            try db.execute(sql: "UPDATE points SET updated_at = ?, head_revision = head_revision + 1 WHERE id = ?",
                           arguments: [Date().timeIntervalSince1970, pointID.rawValue.uuidString])
            let revision = try Int.fetchOne(db, sql: "SELECT head_revision FROM points WHERE id = ?", arguments: [pointID.rawValue.uuidString]) ?? 1
            try enqueueEmbedding(pointID: pointID, revision: revision, db: db, timestamp: Date().timeIntervalSince1970)
        }
    }

    public func images(pointID: PointID) async throws -> [PointImage] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: "SELECT id, relative_path, recognized_text, created_at FROM point_images WHERE point_id = ? ORDER BY created_at",
                             arguments: [pointID.rawValue.uuidString]).compactMap { row in
                guard let id = UUID(uuidString: row["id"]) else { return nil }
                return PointImage(id: id, relativePath: row["relative_path"], recognizedText: row["recognized_text"], createdAt: Date(timeIntervalSince1970: row["created_at"]))
            }
        }
    }

    public func removeImage(id: UUID) async throws -> String {
        try await writer.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT relative_path, point_id FROM point_images WHERE id = ?", arguments: [id.uuidString]) else {
                throw PointVerseError.databaseCommitFailed
            }
            try db.execute(sql: "DELETE FROM point_images WHERE id = ?", arguments: [id.uuidString])
            let pointID = PointID(rawValue: UUID(uuidString: row["point_id"])!)
            let timestamp = Date().timeIntervalSince1970
            let revision = try bumpRevision(pointID: pointID, db: db, timestamp: timestamp)
            try enqueueEmbedding(pointID: pointID, revision: revision, db: db, timestamp: timestamp)
            return row["relative_path"]
        }
    }

    public func updateImageText(id: UUID, recognizedText: String?) async throws {
        try await writer.write { db in
            guard let rawPointID = try String.fetchOne(db, sql: "SELECT point_id FROM point_images WHERE id = ?", arguments: [id.uuidString]),
                  let uuid = UUID(uuidString: rawPointID) else { throw PointVerseError.databaseCommitFailed }
            try db.execute(sql: "UPDATE point_images SET recognized_text = ? WHERE id = ?",
                           arguments: [recognizedText, id.uuidString])
            let pointID = PointID(rawValue: uuid)
            let timestamp = Date().timeIntervalSince1970
            let revision = try bumpRevision(pointID: pointID, db: db, timestamp: timestamp)
            try enqueueEmbedding(pointID: pointID, revision: revision, db: db, timestamp: timestamp)
        }
    }

    public func deletePoint(id: PointID) async throws -> String? {
        try await writer.write { db in
            let path = try String.fetchOne(db, sql: """
                SELECT a.relative_path FROM audio_assets a
                JOIN messages m ON m.id = a.message_id WHERE m.point_id = ? LIMIT 1
                """, arguments: [id.rawValue.uuidString])
            try db.execute(sql: "DELETE FROM point_search WHERE point_id = ?", arguments: [id.rawValue.uuidString])
            try db.execute(sql: "DELETE FROM points WHERE id = ?", arguments: [id.rawValue.uuidString])
            return path
        }
    }

    public func saveUserTranscript(pointID: PointID, userText: String) async throws {
        try await writer.write { db in
            let timestamp = Date().timeIntervalSince1970
            try db.execute(sql: """
                UPDATE transcripts SET user_text = ?, updated_at = ?
                WHERE asset_id = (SELECT a.id FROM audio_assets a JOIN messages m ON m.id = a.message_id WHERE m.point_id = ? LIMIT 1)
                """, arguments: [userText, timestamp, pointID.rawValue.uuidString])
            try db.execute(sql: """
                UPDATE transcription_candidates SET user_text = ?, updated_at = ?
                WHERE is_selected = 1 AND asset_id = (
                    SELECT a.id FROM audio_assets a JOIN messages m ON m.id = a.message_id WHERE m.point_id = ? LIMIT 1
                )
                """, arguments: [userText, timestamp, pointID.rawValue.uuidString])
            try refreshSearch(pointID: pointID, db: db)
            let revision = try bumpRevision(pointID: pointID, db: db, timestamp: timestamp)
            try enqueueEmbedding(pointID: pointID, revision: revision, db: db, timestamp: timestamp)
        }
    }

    public func audioUnderstanding(pointID: PointID) async throws -> AudioUnderstanding? {
        try await writer.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM audio_understanding WHERE point_id = ?",
                                             arguments: [pointID.rawValue.uuidString]) else { return nil }
            let data = Data((row["semantic_tags_json"] as String).utf8)
            let tags = (try? JSONDecoder().decode([String].self, from: data)) ?? []
            return AudioUnderstanding(
                durationSeconds: row["duration_seconds"], loudnessDB: row["loudness_db"],
                bpm: row["bpm"], dominantPitchHz: row["dominant_pitch_hz"],
                rhythmStrength: row["rhythm_strength"], semanticTags: tags,
                clapModelID: row["clap_model_id"], hasVoice: row["has_voice"],
                updatedAt: Date(timeIntervalSince1970: row["updated_at"])
            )
        }
    }

    public func saveAudioUnderstanding(pointID: PointID, value: AudioUnderstanding, semanticVector: [Float]?) async throws {
        try await writer.write { db in
            let tags = String(data: try JSONEncoder().encode(value.semanticTags), encoding: .utf8) ?? "[]"
            let vectorData = semanticVector.map(EmbeddingMath.encodeFloat16)
            let timestamp = value.updatedAt.timeIntervalSince1970
            try db.execute(sql: """
                INSERT INTO audio_understanding
                    (point_id, duration_seconds, loudness_db, bpm, dominant_pitch_hz, rhythm_strength,
                     semantic_tags_json, clap_model_id, clap_vector, clap_dimension, has_voice, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(point_id) DO UPDATE SET
                    duration_seconds=excluded.duration_seconds, loudness_db=excluded.loudness_db,
                    bpm=excluded.bpm, dominant_pitch_hz=excluded.dominant_pitch_hz,
                    rhythm_strength=excluded.rhythm_strength, semantic_tags_json=excluded.semantic_tags_json,
                    clap_model_id=excluded.clap_model_id, clap_vector=excluded.clap_vector,
                    clap_dimension=excluded.clap_dimension, has_voice=excluded.has_voice,
                    updated_at=excluded.updated_at
                """, arguments: [pointID.rawValue.uuidString, value.durationSeconds, value.loudnessDB,
                                   value.bpm, value.dominantPitchHz, value.rhythmStrength, tags,
                                   value.clapModelID, vectorData, semanticVector?.count, value.hasVoice, timestamp])
            try refreshSearch(pointID: pointID, db: db)
            let revision = try bumpRevision(pointID: pointID, db: db, timestamp: timestamp)
            try enqueueEmbedding(pointID: pointID, revision: revision, db: db, timestamp: timestamp)
        }
    }

    public func transcriptionCandidates(pointID: PointID) async throws -> [TranscriptionCandidate] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT c.id, c.model_id, c.engine_text, c.user_text, c.is_selected, c.updated_at
                FROM transcription_candidates c
                JOIN audio_assets a ON a.id = c.asset_id
                JOIN messages m ON m.id = a.message_id
                WHERE m.point_id = ? ORDER BY c.is_selected DESC, c.updated_at DESC
                """, arguments: [pointID.rawValue.uuidString]).compactMap { row in
                    guard let id = UUID(uuidString: row["id"]) else { return nil }
                    return TranscriptionCandidate(id: id, modelID: row["model_id"], engineText: row["engine_text"],
                                                  userText: row["user_text"], isSelected: row["is_selected"],
                                                  updatedAt: Date(timeIntervalSince1970: row["updated_at"]))
                }
        }
    }

    public func saveTranscriptionCandidate(pointID: PointID, text: String, modelID: String, modelSHA256: String, select: Bool) async throws {
        try await writer.write { db in
            guard let assetID = try String.fetchOne(db, sql: "SELECT a.id FROM audio_assets a JOIN messages m ON m.id = a.message_id WHERE m.point_id = ? LIMIT 1", arguments: [pointID.rawValue.uuidString]) else { throw PointVerseError.databaseCommitFailed }
            let now = Date().timeIntervalSince1970
            if select { try db.execute(sql: "UPDATE transcription_candidates SET is_selected = 0 WHERE asset_id = ?", arguments: [assetID]) }
            try db.execute(sql: """
                INSERT INTO transcription_candidates
                    (id, asset_id, model_id, model_sha256, engine_text, is_selected, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(asset_id, model_id) DO UPDATE SET model_sha256=excluded.model_sha256,
                    engine_text=excluded.engine_text, user_text=NULL,
                    is_selected=excluded.is_selected, updated_at=excluded.updated_at
                """, arguments: [UUID().uuidString, assetID, modelID, modelSHA256, text, select, now, now])
            if select { try activateCandidate(assetID: assetID, modelID: modelID, pointID: pointID, db: db, timestamp: now) }
        }
    }

    public func selectTranscriptionCandidate(pointID: PointID, candidateID: UUID) async throws {
        try await writer.write { db in
            let now = Date().timeIntervalSince1970
            guard let row = try Row.fetchOne(db, sql: "SELECT asset_id, model_id FROM transcription_candidates WHERE id = ?", arguments: [candidateID.uuidString]) else { throw PointVerseError.databaseCommitFailed }
            let assetID: String = row["asset_id"], modelID: String = row["model_id"]
            try db.execute(sql: "UPDATE transcription_candidates SET is_selected = CASE WHEN id = ? THEN 1 ELSE 0 END WHERE asset_id = ?", arguments: [candidateID.uuidString, assetID])
            try activateCandidate(assetID: assetID, modelID: modelID, pointID: pointID, db: db, timestamp: now)
        }
    }

    public func editTranscriptionCandidate(pointID: PointID, candidateID: UUID, text: String) async throws {
        try await writer.write { db in
            let now = Date().timeIntervalSince1970
            try db.execute(sql: "UPDATE transcription_candidates SET user_text = ?, updated_at = ? WHERE id = ?", arguments: [text, now, candidateID.uuidString])
            guard let row = try Row.fetchOne(db, sql: "SELECT asset_id, model_id, is_selected FROM transcription_candidates WHERE id = ?", arguments: [candidateID.uuidString]) else { return }
            if (row["is_selected"] as Bool) {
                try activateCandidate(assetID: row["asset_id"], modelID: row["model_id"], pointID: pointID, db: db, timestamp: now)
            }
        }
    }

    private func activateCandidate(assetID: String, modelID: String, pointID: PointID, db: Database, timestamp: Double) throws {
        try db.execute(sql: """
            UPDATE transcripts SET engine_text = (SELECT engine_text FROM transcription_candidates WHERE asset_id=? AND model_id=?),
                user_text = (SELECT user_text FROM transcription_candidates WHERE asset_id=? AND model_id=?),
                model_id=?, model_sha256=(SELECT model_sha256 FROM transcription_candidates WHERE asset_id=? AND model_id=?),
                state='succeeded', error_code=NULL, updated_at=? WHERE asset_id=?
            """, arguments: [assetID, modelID, assetID, modelID, modelID, assetID, modelID, timestamp, assetID])
        try refreshSearch(pointID: pointID, db: db)
        let revision = try bumpRevision(pointID: pointID, db: db, timestamp: timestamp)
        try enqueueEmbedding(pointID: pointID, revision: revision, db: db, timestamp: timestamp)
    }

    public func queuedEmbeddingDocuments(modelID: String) async throws -> [PointSemanticDocument] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT p.id, p.head_revision,
                       TRIM(COALESCE(m.user_text, t.user_text, t.engine_text, '') || ' ' ||
                            COALESCE((SELECT GROUP_CONCAT(recognized_text, ' ') FROM point_images
                                      WHERE point_id = p.id AND recognized_text IS NOT NULL), '') || ' ' ||
                            COALESCE((SELECT GROUP_CONCAT(user_text, ' ') FROM messages
                                      WHERE point_id = p.id AND sequence > 1 AND role = 'user'
                                        AND user_text IS NOT NULL), '') || ' ' ||
                            COALESCE((SELECT semantic_tags_json FROM audio_understanding
                                      WHERE point_id = p.id), '')) AS semantic_text,
                       COALESCE(t.locale, '') AS locale
                FROM points p
                LEFT JOIN messages m ON m.point_id = p.id AND m.sequence = 1
                LEFT JOIN audio_assets a ON a.message_id = m.id
                LEFT JOIN transcripts t ON t.asset_id = a.id
                WHERE NOT EXISTS (
                    SELECT 1 FROM point_embeddings e
                    WHERE e.point_id = p.id
                      AND e.model_id = ?
                      AND e.content_revision = p.head_revision
                )
                ORDER BY p.updated_at
                """, arguments: [modelID]).compactMap { row in
                    guard let uuid = UUID(uuidString: row["id"]) else { return nil }
                    return PointSemanticDocument(pointID: PointID(rawValue: uuid), revision: row["head_revision"],
                                                 text: row["semantic_text"], localeIdentifier: row["locale"])
                }
        }
    }

    public func saveEmbedding(_ record: PointEmbeddingRecord) async throws {
        try await writer.write { db in
            guard let current = try Int.fetchOne(db, sql: "SELECT head_revision FROM points WHERE id = ?", arguments: [record.pointID.rawValue.uuidString]),
                  current == record.revision else { return }
            let timestamp = Date().timeIntervalSince1970
            try db.execute(sql: """
                INSERT INTO point_embeddings (point_id, content_revision, model_id, dimension, storage_format, vector, created_at)
                VALUES (?, ?, ?, ?, 'float16-le', ?, ?)
                ON CONFLICT(point_id, model_id) DO UPDATE SET
                    content_revision = excluded.content_revision, dimension = excluded.dimension,
                    storage_format = excluded.storage_format, vector = excluded.vector, created_at = excluded.created_at
                """, arguments: [record.pointID.rawValue.uuidString, record.revision, record.modelID,
                                   record.vector.count, EmbeddingMath.encodeFloat16(record.vector), timestamp])
            try db.execute(sql: "UPDATE durable_tasks SET state = 'succeeded', updated_at = ? WHERE operation_id = ?",
                           arguments: [timestamp, Self.embeddingOperationID(pointID: record.pointID, revision: record.revision, modelID: record.modelID)])
        }
    }

    public func embeddings(modelID: String) async throws -> [PointEmbeddingRecord] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT e.point_id, e.content_revision, e.model_id, e.dimension, e.vector
                FROM point_embeddings e JOIN points p ON p.id = e.point_id
                WHERE e.model_id = ? AND e.content_revision = p.head_revision
                """, arguments: [modelID]).compactMap { row in
                    guard let uuid = UUID(uuidString: row["point_id"]),
                          let vector = EmbeddingMath.decodeFloat16(row["vector"], dimension: row["dimension"]) else { return nil }
                    return PointEmbeddingRecord(pointID: PointID(rawValue: uuid), revision: row["content_revision"],
                                                modelID: row["model_id"], vector: vector)
                }
        }
    }

    public func geographies(version: String) async throws -> [PointGeographyRecord] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT point_id, geography_version, content_revision, community_id,
                       latitude, longitude, altitude, placement_confidence, is_pinned
                FROM point_geography
                WHERE geography_version = ?
                """, arguments: [version]).compactMap { row in
                    guard let uuid = UUID(uuidString: row["point_id"]) else { return nil }
                    return PointGeographyRecord(
                        pointID: PointID(rawValue: uuid),
                        geographyVersion: row["geography_version"],
                        contentRevision: row["content_revision"],
                        communityID: row["community_id"],
                        latitude: row["latitude"],
                        longitude: row["longitude"],
                        altitude: row["altitude"],
                        placementConfidence: row["placement_confidence"],
                        isPinned: row["is_pinned"]
                    )
                }
        }
    }

    public func saveGeographies(_ records: [PointGeographyRecord]) async throws {
        guard !records.isEmpty else { return }
        try await writer.write { db in
            let timestamp = Date().timeIntervalSince1970
            for record in records {
                try db.execute(sql: """
                    INSERT INTO point_geography (
                        point_id, geography_version, content_revision, community_id,
                        latitude, longitude, altitude, placement_confidence, is_pinned, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(point_id, geography_version) DO UPDATE SET
                        content_revision = excluded.content_revision,
                        community_id = excluded.community_id,
                        latitude = CASE WHEN point_geography.is_pinned = 1 THEN point_geography.latitude ELSE excluded.latitude END,
                        longitude = CASE WHEN point_geography.is_pinned = 1 THEN point_geography.longitude ELSE excluded.longitude END,
                        altitude = excluded.altitude,
                        placement_confidence = excluded.placement_confidence,
                        is_pinned = point_geography.is_pinned,
                        updated_at = excluded.updated_at
                    """, arguments: [
                        record.pointID.rawValue.uuidString, record.geographyVersion, record.contentRevision,
                        record.communityID, record.latitude, record.longitude, record.altitude,
                        record.placementConfidence, record.isPinned, timestamp
                    ])
            }
        }
    }

    public func relatedPoints(
        to pointID: PointID,
        modelID: String,
        minimumScore: Float = 0.85,
        limit: Int = 5
    ) async throws -> [RelatedPoint] {
        let records = try await embeddings(modelID: modelID)
        guard let source = records.first(where: { $0.pointID == pointID }) else { return [] }
        let hits = EmbeddingMath.topK(query: source.vector, records: records, excluding: pointID, limit: max(limit * 3, limit))
            .filter { $0.score >= minimumScore }
            .prefix(limit)
        let entries = try await pointMapEntries()
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        return hits.compactMap { hit in
            guard let entry = byID[hit.pointID] else { return nil }
            return RelatedPoint(point: entry.point, content: entry.content, score: hit.score)
        }
    }

    public func failTranscription(pointID: PointID, error: PointVerseError) async throws {
        try await writer.write { db in
            let timestamp = Date().timeIntervalSince1970
            try db.execute(sql: """
                UPDATE transcripts SET state = 'failed', error_code = ?, updated_at = ?
                WHERE asset_id = (SELECT a.id FROM audio_assets a JOIN messages m ON m.id = a.message_id WHERE m.point_id = ? LIMIT 1)
                """, arguments: [error.rawValue, timestamp, pointID.rawValue.uuidString])
            try db.execute(sql: """
                UPDATE durable_tasks SET state = 'failed', last_error_code = ?, updated_at = ?
                WHERE operation_id = 'transcribe:' || (
                    SELECT a.id FROM audio_assets a JOIN messages m ON m.id = a.message_id WHERE m.point_id = ? LIMIT 1
                )
                """, arguments: [error.rawValue, timestamp, pointID.rawValue.uuidString])
        }
    }

    private func updateTranscript(pointID: PointID, sql: String, arguments: StatementArguments) async throws {
        try await writer.write { db in try db.execute(sql: sql, arguments: arguments) }
    }

    private func refreshSearch(pointID: PointID, db: Database) throws {
        try db.execute(sql: "DELETE FROM point_search WHERE point_id = ?", arguments: [pointID.rawValue.uuidString])
        try db.execute(sql: """
            INSERT INTO point_search (point_id, accepted_title, transcript_text, summary, tags)
            SELECT p.id, COALESCE(p.accepted_title, d.title, ''),
                   TRIM(COALESCE(m.user_text, t.user_text, t.engine_text, '') || ' ' ||
                        COALESCE((SELECT GROUP_CONCAT(user_text, ' ') FROM messages
                                  WHERE point_id = p.id AND sequence > 1 AND user_text IS NOT NULL), '') || ' ' ||
                        COALESCE((SELECT GROUP_CONCAT(recognized_text, ' ') FROM point_images
                                  WHERE point_id = p.id AND recognized_text IS NOT NULL), '')),
                   COALESCE(d.summary, ''), COALESCE(d.tags_json, '')
            FROM points p
            JOIN messages m ON m.point_id = p.id AND m.sequence = 1
            LEFT JOIN audio_assets a ON a.message_id = m.id
            LEFT JOIN transcripts t ON t.asset_id = a.id
            LEFT JOIN derivations d ON d.id = (
                SELECT id FROM derivations WHERE point_id = p.id AND state = 'succeeded'
                ORDER BY created_at DESC, rowid DESC LIMIT 1
            )
            WHERE p.id = ? LIMIT 1
            """, arguments: [pointID.rawValue.uuidString])
    }

    private func bumpRevision(pointID: PointID, db: Database, timestamp: Double) throws -> Int {
        try db.execute(sql: "UPDATE points SET head_revision = head_revision + 1, updated_at = ? WHERE id = ?",
                       arguments: [timestamp, pointID.rawValue.uuidString])
        return try Int.fetchOne(db, sql: "SELECT head_revision FROM points WHERE id = ?", arguments: [pointID.rawValue.uuidString]) ?? 1
    }

    private func enqueueEmbedding(pointID: PointID, revision: Int, db: Database, timestamp: Double) throws {
        let modelID = EmbeddingModelIdentity.bgeSmallZhV15
        let operationID = Self.embeddingOperationID(pointID: pointID, revision: revision, modelID: modelID)
        let payload = "{\"pointId\":\"\(pointID.rawValue.uuidString)\",\"revision\":\(revision),\"modelId\":\"\(modelID)\"}"
        try db.execute(sql: """
            INSERT OR IGNORE INTO durable_tasks
                (id, operation_id, kind, payload_json, state, next_run_at, created_at, updated_at)
            VALUES (?, ?, 'embedding', ?, 'queued', ?, ?, ?)
            """, arguments: [UUID().uuidString, operationID, payload, timestamp, timestamp, timestamp])
    }

    private static func embeddingOperationID(pointID: PointID, revision: Int, modelID: String) -> String {
        "embedding:\(pointID.rawValue.uuidString):\(revision):\(modelID)"
    }

    private static func createV1(in db: Database) throws {
        try db.execute(sql: Schema.v1)
    }
}

private enum Schema {
    static let v1 = """
    CREATE TABLE points (id TEXT PRIMARY KEY NOT NULL, accepted_title TEXT, status TEXT NOT NULL DEFAULT 'active', head_revision INTEGER NOT NULL DEFAULT 1, created_at REAL NOT NULL, updated_at REAL NOT NULL);
    CREATE TABLE messages (id TEXT PRIMARY KEY NOT NULL, operation_id TEXT NOT NULL UNIQUE, point_id TEXT NOT NULL REFERENCES points(id) ON DELETE CASCADE, sequence INTEGER NOT NULL, role TEXT NOT NULL CHECK (role IN ('user','assistant')), modality TEXT NOT NULL CHECK (modality IN ('voice','text')), user_text TEXT, created_at REAL NOT NULL, UNIQUE(point_id, sequence));
    CREATE TABLE audio_assets (id TEXT PRIMARY KEY NOT NULL, message_id TEXT NOT NULL UNIQUE REFERENCES messages(id) ON DELETE CASCADE, relative_path TEXT NOT NULL UNIQUE, sha256 TEXT NOT NULL, byte_count INTEGER NOT NULL, duration_ms INTEGER NOT NULL, codec TEXT NOT NULL, sample_rate INTEGER NOT NULL, state TEXT NOT NULL CHECK (state IN ('committing','available','quarantined')), created_at REAL NOT NULL);
    CREATE TABLE transcripts (id TEXT PRIMARY KEY NOT NULL, asset_id TEXT NOT NULL UNIQUE REFERENCES audio_assets(id) ON DELETE CASCADE, engine_text TEXT, user_text TEXT, locale TEXT NOT NULL, model_id TEXT NOT NULL, model_sha256 TEXT NOT NULL, state TEXT NOT NULL CHECK (state IN ('queued','running','succeeded','failed')), error_code TEXT, created_at REAL NOT NULL, updated_at REAL NOT NULL);
    CREATE TABLE derivations (id TEXT PRIMARY KEY NOT NULL, point_id TEXT NOT NULL REFERENCES points(id) ON DELETE CASCADE, input_revision INTEGER NOT NULL, model_id TEXT NOT NULL, model_sha256 TEXT NOT NULL, prompt_version TEXT NOT NULL, title TEXT, summary TEXT, tags_json TEXT, next_question TEXT, raw_json TEXT, state TEXT NOT NULL CHECK (state IN ('queued','running','succeeded','failed')), adoption TEXT NOT NULL DEFAULT 'candidate', error_code TEXT, created_at REAL NOT NULL);
    CREATE TABLE durable_tasks (id TEXT PRIMARY KEY NOT NULL, operation_id TEXT NOT NULL UNIQUE, kind TEXT NOT NULL CHECK (kind IN ('transcribe','derive')), payload_json TEXT NOT NULL, state TEXT NOT NULL CHECK (state IN ('queued','running','succeeded','failed','cancelled')), attempt_count INTEGER NOT NULL DEFAULT 0, next_run_at REAL NOT NULL, lease_until REAL, last_error_code TEXT, created_at REAL NOT NULL, updated_at REAL NOT NULL);
    CREATE VIRTUAL TABLE point_search USING fts5(point_id UNINDEXED, accepted_title, transcript_text, summary, tags, tokenize = 'unicode61');
    """

    static let v3Embeddings = """
    ALTER TABLE durable_tasks RENAME TO durable_tasks_v2;
    CREATE TABLE durable_tasks (id TEXT PRIMARY KEY NOT NULL, operation_id TEXT NOT NULL UNIQUE, kind TEXT NOT NULL CHECK (kind IN ('transcribe','derive','embedding','relationRefresh')), payload_json TEXT NOT NULL, state TEXT NOT NULL CHECK (state IN ('queued','running','succeeded','failed','cancelled')), attempt_count INTEGER NOT NULL DEFAULT 0, next_run_at REAL NOT NULL, lease_until REAL, last_error_code TEXT, created_at REAL NOT NULL, updated_at REAL NOT NULL);
    INSERT INTO durable_tasks SELECT * FROM durable_tasks_v2;
    DROP TABLE durable_tasks_v2;
    CREATE TABLE point_embeddings (
        point_id TEXT NOT NULL REFERENCES points(id) ON DELETE CASCADE,
        content_revision INTEGER NOT NULL,
        model_id TEXT NOT NULL,
        dimension INTEGER NOT NULL,
        storage_format TEXT NOT NULL CHECK (storage_format IN ('float16-le')),
        vector BLOB NOT NULL,
        created_at REAL NOT NULL,
        PRIMARY KEY(point_id, model_id)
    );
    CREATE INDEX point_embeddings_model_revision ON point_embeddings(model_id, content_revision);
    CREATE TABLE relation_candidates (
        source_point_id TEXT NOT NULL REFERENCES points(id) ON DELETE CASCADE,
        target_point_id TEXT NOT NULL REFERENCES points(id) ON DELETE CASCADE,
        source_revision INTEGER NOT NULL,
        target_revision INTEGER NOT NULL,
        model_id TEXT NOT NULL,
        cosine_score REAL NOT NULL,
        created_at REAL NOT NULL,
        PRIMARY KEY(source_point_id, target_point_id, model_id)
    );
    CREATE TABLE point_relations (
        source_point_id TEXT NOT NULL REFERENCES points(id) ON DELETE CASCADE,
        target_point_id TEXT NOT NULL REFERENCES points(id) ON DELETE CASCADE,
        relation_type TEXT NOT NULL CHECK (relation_type IN ('duplicate','extend','contradict','related')),
        confidence REAL NOT NULL,
        judge_model_id TEXT NOT NULL,
        explanation TEXT,
        created_at REAL NOT NULL,
        PRIMARY KEY(source_point_id, target_point_id, judge_model_id)
    );
    """
}
