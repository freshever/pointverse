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
        try migrator.migrate(writer)
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

    public func listPoints(matching query: String) async throws -> [PointSummary] {
        try await writer.read { db in
            let rows: [Row]
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                rows = try Row.fetchAll(db, sql: """
                    SELECT p.id, COALESCE(p.accepted_title, d.title, '') AS title,
                           p.created_at, t.state AS transcript_state
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
                           p.created_at, t.state AS transcript_state
                    FROM points p
                    LEFT JOIN messages m ON m.point_id = p.id AND m.sequence = 1
                    LEFT JOIN audio_assets a ON a.message_id = m.id
                    LEFT JOIN transcripts t ON t.asset_id = a.id
                    LEFT JOIN derivations d ON d.id = (SELECT id FROM derivations WHERE point_id = p.id AND state = 'succeeded' ORDER BY created_at DESC, rowid DESC LIMIT 1)
                    WHERE COALESCE(p.accepted_title, d.title, '') LIKE ? ESCAPE '\\'
                       OR COALESCE(t.user_text, t.engine_text, '') LIKE ? ESCAPE '\\'
                       OR COALESCE(d.summary, '') LIKE ? ESCAPE '\\'
                       OR COALESCE(d.tags_json, '') LIKE ? ESCAPE '\\'
                       OR EXISTS (SELECT 1 FROM point_images pi WHERE pi.point_id = p.id AND COALESCE(pi.recognized_text, '') LIKE ? ESCAPE '\\')
                    ORDER BY p.created_at DESC
                    """, arguments: [pattern, pattern, pattern, pattern, pattern])
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
                       a.relative_path, a.duration_ms, t.state AS transcript_state,
                       t.engine_text, t.user_text, t.locale, t.error_code
                FROM points p
                JOIN messages m ON m.point_id = p.id AND m.sequence = 1
                JOIN audio_assets a ON a.message_id = m.id
                JOIN transcripts t ON t.asset_id = a.id
                LEFT JOIN derivations d ON d.id = (SELECT id FROM derivations WHERE point_id = p.id AND state = 'succeeded' ORDER BY created_at DESC, rowid DESC LIMIT 1)
                WHERE p.id = ?
                """, arguments: [id.rawValue.uuidString]) else {
                throw PointVerseError.databaseCommitFailed
            }
            return PointDetail(
                id: id,
                title: row["title"],
                audioRelativePath: row["relative_path"],
                durationMilliseconds: row["duration_ms"],
                transcriptState: row["transcript_state"],
                transcriptErrorCode: row["error_code"],
                engineText: row["engine_text"],
                userText: row["user_text"],
                localeIdentifier: row["locale"]
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
            guard let path = try String.fetchOne(db, sql: "SELECT relative_path FROM point_images WHERE id = ?", arguments: [id.uuidString]) else {
                throw PointVerseError.databaseCommitFailed
            }
            try db.execute(sql: "DELETE FROM point_images WHERE id = ?", arguments: [id.uuidString])
            return path
        }
    }

    public func updateImageText(id: UUID, recognizedText: String?) async throws {
        try await writer.write { db in
            try db.execute(sql: "UPDATE point_images SET recognized_text = ? WHERE id = ?",
                           arguments: [recognizedText, id.uuidString])
        }
    }

    public func deletePoint(id: PointID) async throws -> String {
        try await writer.write { db in
            guard let path = try String.fetchOne(db, sql: """
                SELECT a.relative_path FROM audio_assets a
                JOIN messages m ON m.id = a.message_id WHERE m.point_id = ? LIMIT 1
                """, arguments: [id.rawValue.uuidString]) else { throw PointVerseError.databaseCommitFailed }
            try db.execute(sql: "DELETE FROM point_search WHERE point_id = ?", arguments: [id.rawValue.uuidString])
            try db.execute(sql: "DELETE FROM points WHERE id = ?", arguments: [id.rawValue.uuidString])
            return path
        }
    }

    public func saveUserTranscript(pointID: PointID, userText: String) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                UPDATE transcripts SET user_text = ?, updated_at = ?
                WHERE asset_id = (SELECT a.id FROM audio_assets a JOIN messages m ON m.id = a.message_id WHERE m.point_id = ? LIMIT 1)
                """, arguments: [userText, Date().timeIntervalSince1970, pointID.rawValue.uuidString])
            try refreshSearch(pointID: pointID, db: db)
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
            SELECT p.id, COALESCE(p.accepted_title, d.title, ''), COALESCE(t.user_text, t.engine_text, ''),
                   COALESCE(d.summary, ''), COALESCE(d.tags_json, '')
            FROM points p
            JOIN messages m ON m.point_id = p.id
            JOIN audio_assets a ON a.message_id = m.id
            JOIN transcripts t ON t.asset_id = a.id
            LEFT JOIN derivations d ON d.id = (
                SELECT id FROM derivations WHERE point_id = p.id AND state = 'succeeded'
                ORDER BY created_at DESC, rowid DESC LIMIT 1
            )
            WHERE p.id = ? LIMIT 1
            """, arguments: [pointID.rawValue.uuidString])
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
}
