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
        try migrator.migrate(writer)
    }

    public func commitVoiceCapture(_ command: VoiceCaptureCommand) async throws -> PointID {
        try await writer.write { db in
            if let existing = try String.fetchOne(
                db,
                sql: "SELECT point_id FROM messages WHERE operation_id = ?",
                arguments: [command.operationID.uuidString]
            ), let uuid = UUID(uuidString: existing) {
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
            return command.pointID
        }
    }

    public func listPoints(matching query: String) async throws -> [PointSummary] {
        try await writer.read { db in
            let rows: [Row]
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                rows = try Row.fetchAll(db, sql: """
                    SELECT p.id, COALESCE(p.accepted_title, '') AS title,
                           p.created_at, t.state AS transcript_state
                    FROM points p
                    LEFT JOIN messages m ON m.point_id = p.id AND m.sequence = 1
                    LEFT JOIN audio_assets a ON a.message_id = m.id
                    LEFT JOIN transcripts t ON t.asset_id = a.id
                    ORDER BY p.created_at DESC
                    """)
            } else {
                rows = try Row.fetchAll(db, sql: """
                    SELECT p.id, COALESCE(p.accepted_title, '') AS title,
                           p.created_at, t.state AS transcript_state
                    FROM point_search s
                    JOIN points p ON p.id = s.point_id
                    LEFT JOIN messages m ON m.point_id = p.id AND m.sequence = 1
                    LEFT JOIN audio_assets a ON a.message_id = m.id
                    LEFT JOIN transcripts t ON t.asset_id = a.id
                    WHERE point_search MATCH ?
                    ORDER BY rank
                    """, arguments: [query])
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

    public func pointDetail(id: PointID) async throws -> PointDetail {
        try await writer.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT p.id, COALESCE(p.accepted_title, '') AS title,
                       a.relative_path, a.duration_ms, t.state AS transcript_state,
                       t.engine_text, t.user_text, t.locale
                FROM points p
                JOIN messages m ON m.point_id = p.id AND m.sequence = 1
                JOIN audio_assets a ON a.message_id = m.id
                JOIN transcripts t ON t.asset_id = a.id
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

    public func markTranscriptionRunning(pointID: PointID) async throws {
        try await updateTranscript(pointID: pointID, sql: """
            UPDATE transcripts SET state = 'running', error_code = NULL, updated_at = ?
            WHERE asset_id = (SELECT a.id FROM audio_assets a JOIN messages m ON m.id = a.message_id WHERE m.point_id = ? LIMIT 1)
            """, arguments: [Date().timeIntervalSince1970, pointID.rawValue.uuidString])
    }

    public func saveTranscript(pointID: PointID, engineText: String) async throws {
        try await writer.write { db in
            let timestamp = Date().timeIntervalSince1970
            try db.execute(sql: """
                UPDATE transcripts SET engine_text = ?, state = 'succeeded', error_code = NULL, updated_at = ?
                WHERE asset_id = (SELECT a.id FROM audio_assets a JOIN messages m ON m.id = a.message_id WHERE m.point_id = ? LIMIT 1)
                """, arguments: [engineText, timestamp, pointID.rawValue.uuidString])
            try db.execute(sql: """
                UPDATE durable_tasks SET state = 'succeeded', updated_at = ?
                WHERE operation_id = 'transcribe:' || (
                    SELECT a.id FROM audio_assets a JOIN messages m ON m.id = a.message_id WHERE m.point_id = ? LIMIT 1
                )
                """, arguments: [timestamp, pointID.rawValue.uuidString])
            try refreshSearch(pointID: pointID, db: db)
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
            SELECT p.id, COALESCE(p.accepted_title, ''), COALESCE(t.user_text, t.engine_text, ''), '', ''
            FROM points p
            JOIN messages m ON m.point_id = p.id
            JOIN audio_assets a ON a.message_id = m.id
            JOIN transcripts t ON t.asset_id = a.id
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
