import Foundation
import GRDB

public final class PointDatabase: PointRepository, @unchecked Sendable {
    private let writer: any DatabaseWriter
    private let databaseURL: URL?

    public init(path: String) throws {
        databaseURL = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        writer = try DatabasePool(path: path, configuration: configuration)
    }

    public init(inMemory: Bool) throws {
        databaseURL = nil
        writer = try DatabaseQueue()
    }

    /// Refuses all databases except the exact isolated test database requested
    /// by the caller. Keeps the live connection and schema intact.
    public func clearIsolatedTestData(expectedURL: URL) async throws -> [String] {
        let expected = expectedURL.standardizedFileURL.resolvingSymlinksInPath()
        guard let databaseURL, databaseURL == expected,
              databaseURL.lastPathComponent == "pointverse-test.sqlite",
              databaseURL.deletingLastPathComponent().lastPathComponent == "test-mode" else {
            throw PointVerseError.databaseCommitFailed
        }
        return try await writer.write { db in
            let paths = try String.fetchAll(db, sql: "SELECT relative_path FROM audio_assets")
                + String.fetchAll(db, sql: "SELECT relative_path FROM point_images")
            try db.execute(sql: "DELETE FROM point_search")
            try db.execute(sql: "DELETE FROM durable_tasks")
            try db.execute(sql: "DELETE FROM points")
            try db.execute(sql: "DELETE FROM speaker_profiles")
            try db.execute(sql: "DELETE FROM province_evaluations")
            return paths
        }
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
        migrator.registerMigration("v7-audio-pitch") { db in
            try db.alter(table: "audio_understanding") { table in
                table.add(column: "detected_notes_json", .text).notNull().defaults(to: "[]")
                table.add(column: "estimated_key", .text)
            }
        }
        migrator.registerMigration("v8-audio-note-sequence") { db in
            try db.alter(table: "audio_understanding") { table in
                table.add(column: "note_sequence_json", .text).notNull().defaults(to: "[]")
            }
        }
        migrator.registerMigration("v9-content-provenance") { db in
            try db.alter(table: "messages") { table in
                table.add(column: "model_id", .text)
            }
        }
        migrator.registerMigration("v10-image-provenance") { db in
            try db.alter(table: "point_images") { table in
                table.add(column: "model_id", .text)
            }
        }
        migrator.registerMigration("v11-rediscovery-loop") { db in
            try db.execute(sql: """
                CREATE TABLE rediscovery_events (
                    id TEXT PRIMARY KEY NOT NULL,
                    point_id TEXT NOT NULL REFERENCES points(id) ON DELETE CASCADE,
                    event_type TEXT NOT NULL CHECK (event_type IN ('shown','opened','useful','notRelated','later','resultSaved')),
                    context TEXT,
                    created_at REAL NOT NULL
                );
                CREATE INDEX rediscovery_events_point_time ON rediscovery_events(point_id, created_at);
                CREATE TABLE confirmed_point_relations (
                    source_point_id TEXT NOT NULL REFERENCES points(id) ON DELETE CASCADE,
                    target_point_id TEXT NOT NULL REFERENCES points(id) ON DELETE CASCADE,
                    relation_type TEXT NOT NULL CHECK (relation_type IN ('similar','extend','support','contradict','analogy')),
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    PRIMARY KEY(source_point_id, target_point_id)
                );
                CREATE TABLE point_origins (
                    point_id TEXT NOT NULL REFERENCES points(id) ON DELETE CASCADE,
                    source_point_id TEXT NOT NULL REFERENCES points(id) ON DELETE CASCADE,
                    origin_type TEXT NOT NULL CHECK (origin_type IN ('playResult','continuedThought')),
                    model_id TEXT,
                    created_at REAL NOT NULL,
                    PRIMARY KEY(point_id, source_point_id)
                );
                """)
        }
        migrator.registerMigration("v12-recording-labels") { db in
            try db.execute(sql: """
                CREATE TABLE speaker_profiles (id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, created_at REAL NOT NULL);
                CREATE TABLE recording_labels (
                    point_id TEXT PRIMARY KEY NOT NULL REFERENCES points(id) ON DELETE CASCADE,
                    speaker_id TEXT REFERENCES speaker_profiles(id) ON DELETE SET NULL,
                    voice_state TEXT NOT NULL DEFAULT 'unknown',
                    source TEXT NOT NULL DEFAULT 'manual', confidence REAL, updated_at REAL NOT NULL
                );
                """)
        }
        migrator.registerMigration("v13-recording-recognition") { db in
            try db.execute(sql: """
                CREATE TABLE recording_recognition (
                    point_id TEXT PRIMARY KEY NOT NULL REFERENCES points(id) ON DELETE CASCADE,
                    speaker_id TEXT REFERENCES speaker_profiles(id) ON DELETE SET NULL,
                    speaker_similarity REAL, voice_state TEXT NOT NULL, emotion_score REAL,
                    raw_emotion TEXT, model_id TEXT NOT NULL, updated_at REAL NOT NULL
                );
                CREATE TABLE recording_voiceprints (
                    point_id TEXT PRIMARY KEY NOT NULL REFERENCES points(id) ON DELETE CASCADE,
                    model_id TEXT NOT NULL, vector BLOB NOT NULL, dimension INTEGER NOT NULL
                );
                """)
        }
        migrator.registerMigration("v14-province-evaluations") { db in
            try db.execute(sql: """
                CREATE TABLE province_evaluations (
                    id TEXT PRIMARY KEY NOT NULL, province_id TEXT NOT NULL,
                    created_at REAL NOT NULL, payload BLOB NOT NULL
                );
                CREATE INDEX province_evaluations_region ON province_evaluations(province_id, created_at);
                """)
        }
        migrator.registerMigration("v15-point-facets") { db in
            try db.execute(sql: """
                CREATE TABLE point_facet_overrides (
                    point_id TEXT NOT NULL REFERENCES points(id) ON DELETE CASCADE,
                    dimension TEXT NOT NULL, values_json BLOB NOT NULL,
                    source TEXT NOT NULL DEFAULT 'manual', updated_at REAL NOT NULL,
                    PRIMARY KEY (point_id, dimension)
                );
                """)
        }
        migrator.registerMigration("v16-lcc-classification-reviews") { db in
            try db.execute(sql: """
                CREATE TABLE lcc_classification_reviews (
                    point_id TEXT PRIMARY KEY NOT NULL REFERENCES points(id) ON DELETE CASCADE,
                    payload BLOB NOT NULL
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

    public func saveProvinceEvaluation(_ evaluation: ProvinceEvaluation) async throws {
        let data = try JSONEncoder().encode(evaluation)
        try await writer.write { db in
            try db.execute(sql: "INSERT INTO province_evaluations (id, province_id, created_at, payload) VALUES (?, ?, ?, ?)",
                           arguments: [evaluation.id.uuidString, evaluation.provinceID, evaluation.createdAt.timeIntervalSince1970, data])
        }
    }

    public func provinceEvaluations(provinceID: String) async throws -> [ProvinceEvaluation] {
        try await writer.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM province_evaluations WHERE province_id = ? ORDER BY created_at DESC",
                              arguments: [provinceID]).map { try JSONDecoder().decode(ProvinceEvaluation.self, from: $0) }
        }
    }

    public func evaluatedScopeIDs() async throws -> Set<String> {
        try await writer.read { db in
            Set(try String.fetchAll(db, sql: "SELECT DISTINCT province_id FROM province_evaluations"))
        }
    }

    public func facetOverrides() async throws -> [PointFacetOverride] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: "SELECT point_id, dimension, values_json FROM point_facet_overrides").compactMap { row in
                guard let uuid = UUID(uuidString: row["point_id"]),
                      let dimension = PointFacetDimension(rawValue: row["dimension"]) else { return nil }
                let data: Data = row["values_json"]
                return PointFacetOverride(pointID: PointID(rawValue: uuid), dimension: dimension,
                                          values: try JSONDecoder().decode([String].self, from: data))
            }
        }
    }

    public func lccClassificationReviews() async throws -> [LCCClassificationReview] {
        try await writer.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM lcc_classification_reviews")
                .map { try JSONDecoder().decode(LCCClassificationReview.self, from: $0) }
        }
    }

    /// Suggestions are separate from manual assignments; saving never changes membership.
    public func saveLCCClassificationReview(_ review: LCCClassificationReview) async throws {
        let data = try JSONEncoder().encode(review)
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO lcc_classification_reviews (point_id, payload) VALUES (?, ?)
                ON CONFLICT(point_id) DO UPDATE SET payload = excluded.payload
                """, arguments: [review.pointID.rawValue.uuidString, data])
        }
        NotificationCenter.default.post(name: ClassificationMapProjection.didChange, object: nil)
    }

    /// Nil restores rule suggestions; [] records a user's explicit empty selection.
    public func saveFacetOverride(pointID: PointID, dimension: PointFacetDimension, values: [String]?) async throws {
        let clean = values.map { Array(Set($0.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted() }
        if let clean {
            guard clean.count <= 40, clean.allSatisfy({ $0.count <= 80 }),
                  dimension == .project || clean.allSatisfy({ value in
                      (dimension == .topic && PointThemeClassifier.themeFromID(value) != nil)
                          || PointFacetEngine.terms.contains { $0.id == value && $0.dimension == dimension }
                  }) else {
                throw PointVerseError.invalidModelOutput
            }
        }
        let data = try clean.map { try JSONEncoder().encode($0) }
        try await writer.write { db in
            if let data {
                try db.execute(sql: """
                    INSERT INTO point_facet_overrides (point_id, dimension, values_json, updated_at) VALUES (?, ?, ?, ?)
                    ON CONFLICT(point_id, dimension) DO UPDATE SET values_json = excluded.values_json, updated_at = excluded.updated_at
                    """, arguments: [pointID.rawValue.uuidString, dimension.rawValue, data, Date().timeIntervalSince1970])
            } else {
                try db.execute(sql: "DELETE FROM point_facet_overrides WHERE point_id = ? AND dimension = ?",
                               arguments: [pointID.rawValue.uuidString, dimension.rawValue])
            }
        }
        NotificationCenter.default.post(name: ClassificationMapProjection.didChange, object: nil)
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

    public func markTestTextProvenance(pointID: PointID, modelID: String) async throws {
        try await writer.write { db in
            try db.execute(sql: "UPDATE messages SET model_id = ? WHERE point_id = ? AND sequence = 1",
                           arguments: [modelID, pointID.rawValue.uuidString])
        }
    }

    public func speakerProfiles() async throws -> [SpeakerProfile] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: "SELECT id, name FROM speaker_profiles ORDER BY created_at").compactMap { row in
                guard let id = UUID(uuidString: row["id"]) else { return nil }
                return SpeakerProfile(id: id, name: row["name"])
            }
        }
    }

    public func createSpeakerProfile(name: String) async throws -> UUID {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 60 else { throw PointVerseError.invalidModelOutput }
        return try await writer.write { db in
            let id = UUID()
            try db.execute(sql: "INSERT INTO speaker_profiles (id, name, created_at) VALUES (?, ?, ?)",
                           arguments: [id.uuidString, value, Date().timeIntervalSince1970])
            return id
        }
    }

    public func deleteSpeakerProfile(id: UUID) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                DELETE FROM recording_voiceprints WHERE point_id IN (
                    SELECT point_id FROM recording_labels WHERE speaker_id = ?
                    UNION SELECT point_id FROM recording_recognition WHERE speaker_id = ?
                )
                """, arguments: [id.uuidString, id.uuidString])
            try db.execute(sql: "DELETE FROM speaker_profiles WHERE id = ?", arguments: [id.uuidString])
        }
    }

    public func recordingLabels() async throws -> [RecordingLabels] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: "SELECT point_id, speaker_id, voice_state, source, confidence FROM recording_labels").compactMap { row in
                guard let id = UUID(uuidString: row["point_id"]) else { return nil }
                let speaker: String? = row["speaker_id"]
                return RecordingLabels(pointID: PointID(rawValue: id), speakerID: speaker.flatMap(UUID.init(uuidString:)),
                    voiceState: RecordingVoiceState(rawValue: row["voice_state"]) ?? .unknown,
                    source: row["source"], confidence: row["confidence"])
            }
        }
    }

    public func speakerReferences(modelID: String, excluding pointID: PointID) async throws -> [SpeakerReference] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT l.speaker_id, v.vector, v.dimension FROM recording_voiceprints v
                JOIN recording_labels l ON l.point_id = v.point_id
                WHERE l.speaker_id IS NOT NULL AND l.source = 'manual' AND v.model_id = ? AND v.point_id != ?
                """, arguments: [modelID, pointID.rawValue.uuidString]).compactMap { row in
                    guard let id = UUID(uuidString: row["speaker_id"]),
                          let vector = EmbeddingMath.decodeFloat16(row["vector"], dimension: row["dimension"]) else { return nil }
                    return SpeakerReference(speakerID: id, vector: vector)
                }
        }
    }

    public func recordingRecognition(pointID: PointID) async throws -> RecordingRecognition? {
        try await writer.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM recording_recognition WHERE point_id = ?", arguments: [pointID.rawValue.uuidString]) else { return nil }
            let speaker: String? = row["speaker_id"]
            return RecordingRecognition(pointID: pointID, speakerID: speaker.flatMap(UUID.init(uuidString:)),
                speakerSimilarity: row["speaker_similarity"], voiceState: RecordingVoiceState(rawValue: row["voice_state"]) ?? .unknown,
                emotionScore: row["emotion_score"], rawEmotion: row["raw_emotion"], modelID: row["model_id"])
        }
    }

    public func saveRecordingRecognition(pointID: PointID, speakerID: UUID?, speakerSimilarity: Double?,
                                          voiceState: RecordingVoiceState, emotionScore: Double?, rawEmotion: String?,
                                          modelID: String, speakerModelID: String, vector: [Float]?) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO recording_recognition (point_id, speaker_id, speaker_similarity, voice_state, emotion_score, raw_emotion, model_id, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(point_id) DO UPDATE SET speaker_id = excluded.speaker_id,
                    speaker_similarity = excluded.speaker_similarity, voice_state = excluded.voice_state,
                    emotion_score = excluded.emotion_score, raw_emotion = excluded.raw_emotion,
                    model_id = excluded.model_id, updated_at = excluded.updated_at
                """, arguments: [pointID.rawValue.uuidString, speakerID?.uuidString, speakerSimilarity,
                                  voiceState.rawValue, emotionScore, rawEmotion, modelID, Date().timeIntervalSince1970])
            if let vector, !vector.isEmpty, vector.allSatisfy({ $0.isFinite }) {
                try db.execute(sql: """
                    INSERT INTO recording_voiceprints (point_id, model_id, vector, dimension) VALUES (?, ?, ?, ?)
                    ON CONFLICT(point_id) DO UPDATE SET model_id = excluded.model_id, vector = excluded.vector, dimension = excluded.dimension
                    """, arguments: [pointID.rawValue.uuidString, speakerModelID, EmbeddingMath.encodeFloat16(vector), vector.count])
            }
        }
    }

    public func saveManualRecordingLabels(pointID: PointID, speakerID: UUID?, voiceState: RecordingVoiceState) async throws {
        try await writer.write { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages m JOIN audio_assets a ON a.message_id = m.id WHERE m.point_id = ?",
                                        arguments: [pointID.rawValue.uuidString]) ?? 0
            guard count > 0 else { throw PointVerseError.invalidModelOutput }
            try db.execute(sql: """
                INSERT INTO recording_labels (point_id, speaker_id, voice_state, source, confidence, updated_at)
                VALUES (?, ?, ?, 'manual', NULL, ?)
                ON CONFLICT(point_id) DO UPDATE SET speaker_id = excluded.speaker_id,
                    voice_state = excluded.voice_state, source = 'manual', confidence = NULL, updated_at = excluded.updated_at
                """, arguments: [pointID.rawValue.uuidString, speakerID?.uuidString, voiceState.rawValue, Date().timeIntervalSince1970])
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
                       m.modality, m.user_text AS source_text, m.model_id AS source_model_id,
                       a.relative_path, a.duration_ms,
                       CASE WHEN m.modality = 'text' THEN 'text' ELSE t.state END AS transcript_state,
                       t.engine_text, t.user_text, COALESCE(t.locale, '') AS locale, t.error_code, t.model_id,
                       d.model_id AS title_model_id
                FROM points p
                JOIN messages m ON m.point_id = p.id AND m.sequence = 1
                LEFT JOIN audio_assets a ON a.message_id = m.id
                LEFT JOIN transcripts t ON t.asset_id = a.id
                LEFT JOIN derivations d ON d.id = (SELECT id FROM derivations WHERE point_id = p.id AND state = 'succeeded' ORDER BY created_at DESC, rowid DESC LIMIT 1)
                WHERE p.id = ?
                """, arguments: [id.rawValue.uuidString]) else {
                throw PointVerseError.databaseCommitFailed
            }
            var detail = PointDetail(
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
                transcriptModelID: row["model_id"],
                titleModelID: row["title_model_id"]
            )
            detail.sourceModelID = row["source_model_id"]
            return detail
        }
    }

    public func queuedTranscriptionPointIDs() async throws -> [PointID] {
        try await writer.read { db in
            try String.fetchAll(db, sql: """
                SELECT m.point_id
                FROM transcripts t
                JOIN audio_assets a ON a.id = t.asset_id
                JOIN messages m ON m.id = a.message_id
                -- Watch audio can arrive while iOS only grants a short
                -- background execution window. Treat a transiently failed
                -- recognition as resumable the next time the app prepares.
                WHERE t.state IN ('queued', 'running', 'failed')
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
                SELECT id, role, user_text, created_at, model_id FROM messages
                WHERE point_id = ? AND modality = 'text' AND user_text IS NOT NULL
                ORDER BY sequence
                """, arguments: [pointID.rawValue.uuidString]).compactMap { row in
                    guard let id = UUID(uuidString: row["id"]), let text: String = row["user_text"] else { return nil }
                    return ConversationMessage(id: id, role: row["role"], text: text,
                                               createdAt: Date(timeIntervalSince1970: row["created_at"]),
                                               modelID: row["model_id"])
                }
        }
    }

    public func appendConversationMessage(pointID: PointID, role: String, text: String, modelID: String? = nil) async throws {
        guard role == "user" || role == "assistant" else { throw PointVerseError.invalidModelOutput }
        try await writer.write { db in
            let sequence = (try Int.fetchOne(db, sql: "SELECT MAX(sequence) FROM messages WHERE point_id = ?", arguments: [pointID.rawValue.uuidString]) ?? 0) + 1
            let id = UUID()
            try db.execute(sql: """
                INSERT INTO messages (id, operation_id, point_id, sequence, role, modality, user_text, created_at, model_id)
                VALUES (?, ?, ?, ?, ?, 'text', ?, ?, ?)
                """, arguments: [id.uuidString, "text:" + id.uuidString, pointID.rawValue.uuidString, sequence, role, text, Date().timeIntervalSince1970, modelID])
            let timestamp = Date().timeIntervalSince1970
            try refreshSearch(pointID: pointID, db: db)
            let revision = try bumpRevision(pointID: pointID, db: db, timestamp: timestamp)
            try enqueueEmbedding(pointID: pointID, revision: revision, db: db, timestamp: timestamp)
        }
    }

    public func addImage(pointID: PointID, id: UUID, relativePath: String, sha256: String, byteCount: Int64,
                         recognizedText: String?, modelID: String? = nil) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO point_images (id, point_id, relative_path, sha256, byte_count, recognized_text, created_at, model_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [id.uuidString, pointID.rawValue.uuidString, relativePath, sha256, byteCount,
                                  recognizedText, Date().timeIntervalSince1970, modelID])
            try db.execute(sql: "UPDATE points SET updated_at = ?, head_revision = head_revision + 1 WHERE id = ?",
                           arguments: [Date().timeIntervalSince1970, pointID.rawValue.uuidString])
            let revision = try Int.fetchOne(db, sql: "SELECT head_revision FROM points WHERE id = ?", arguments: [pointID.rawValue.uuidString]) ?? 1
            try enqueueEmbedding(pointID: pointID, revision: revision, db: db, timestamp: Date().timeIntervalSince1970)
        }
    }

    public func images(pointID: PointID) async throws -> [PointImage] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: "SELECT id, relative_path, recognized_text, created_at, model_id FROM point_images WHERE point_id = ? ORDER BY created_at",
                             arguments: [pointID.rawValue.uuidString]).compactMap { row in
                guard let id = UUID(uuidString: row["id"]) else { return nil }
                return PointImage(id: id, relativePath: row["relative_path"], recognizedText: row["recognized_text"],
                                  createdAt: Date(timeIntervalSince1970: row["created_at"]), modelID: row["model_id"])
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
            let notesData = Data((row["detected_notes_json"] as String).utf8)
            let notes = (try? JSONDecoder().decode([String].self, from: notesData)) ?? []
            let sequenceData = Data((row["note_sequence_json"] as String).utf8)
            let sequence = (try? JSONDecoder().decode([DetectedNoteEvent].self, from: sequenceData)) ?? []
            return AudioUnderstanding(
                durationSeconds: row["duration_seconds"], loudnessDB: row["loudness_db"],
                bpm: row["bpm"], dominantPitchHz: row["dominant_pitch_hz"],
                detectedNotes: notes, estimatedKey: row["estimated_key"],
                noteSequence: sequence,
                rhythmStrength: row["rhythm_strength"], semanticTags: tags,
                clapModelID: row["clap_model_id"], hasVoice: row["has_voice"],
                updatedAt: Date(timeIntervalSince1970: row["updated_at"])
            )
        }
    }

    public func saveAudioUnderstanding(pointID: PointID, value: AudioUnderstanding, semanticVector: [Float]?) async throws {
        try await writer.write { db in
            let tags = String(data: try JSONEncoder().encode(value.semanticTags), encoding: .utf8) ?? "[]"
            let notes = String(data: try JSONEncoder().encode(value.detectedNotes), encoding: .utf8) ?? "[]"
            let sequence = String(data: try JSONEncoder().encode(value.noteSequence), encoding: .utf8) ?? "[]"
            let vectorData = semanticVector.map(EmbeddingMath.encodeFloat16)
            let timestamp = value.updatedAt.timeIntervalSince1970
            try db.execute(sql: """
                INSERT INTO audio_understanding
                    (point_id, duration_seconds, loudness_db, bpm, dominant_pitch_hz, rhythm_strength,
                     semantic_tags_json, detected_notes_json, estimated_key, note_sequence_json,
                     clap_model_id, clap_vector, clap_dimension, has_voice, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(point_id) DO UPDATE SET
                    duration_seconds=excluded.duration_seconds, loudness_db=excluded.loudness_db,
                    bpm=excluded.bpm, dominant_pitch_hz=excluded.dominant_pitch_hz,
                    rhythm_strength=excluded.rhythm_strength, semantic_tags_json=excluded.semantic_tags_json,
                    detected_notes_json=excluded.detected_notes_json, estimated_key=excluded.estimated_key,
                    note_sequence_json=excluded.note_sequence_json,
                    clap_model_id=excluded.clap_model_id, clap_vector=excluded.clap_vector,
                    clap_dimension=excluded.clap_dimension, has_voice=excluded.has_voice,
                    updated_at=excluded.updated_at
                """, arguments: [pointID.rawValue.uuidString, value.durationSeconds, value.loudnessDB,
                                   value.bpm, value.dominantPitchHz, value.rhythmStrength, tags, notes, value.estimatedKey, sequence,
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
        minimumScore: Float = 0.38,
        limit: Int = 5
    ) async throws -> [RelatedPoint] {
        let records = try await embeddings(modelID: modelID)
        guard records.contains(where: { $0.pointID == pointID }) else { return [] }
        let hits = EmbeddingMath.relativeTopK(records: records, query: pointID, limit: max(limit * 3, limit))
            .filter { $0.score >= minimumScore }
            .prefix(limit)
        let entries = try await pointMapEntries()
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        return hits.compactMap { hit in
            guard let entry = byID[hit.pointID] else { return nil }
            return RelatedPoint(point: entry.point, content: entry.content, score: hit.score)
        }
    }

    public func rediscoveryItems(referenceDate: Date = Date(), limit: Int = 4) async throws -> [RediscoveryItem] {
        guard limit > 0 else { return [] }
        let cutoff = referenceDate.addingTimeInterval(-7 * 24 * 60 * 60).timeIntervalSince1970
        let recentEventCutoff = referenceDate.addingTimeInterval(-24 * 60 * 60).timeIntervalSince1970
        let candidates: [PointMapEntry] = try await writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT p.id, COALESCE(p.accepted_title, d.title, '') AS title, p.created_at,
                       CASE WHEN m.modality = 'text' THEN 'text' ELSE t.state END AS transcript_state,
                       TRIM(COALESCE(m.user_text, t.user_text, t.engine_text, '')) AS content,
                       COALESCE(t.locale, '') AS locale
                FROM points p
                JOIN messages m ON m.point_id = p.id AND m.sequence = 1
                LEFT JOIN audio_assets a ON a.message_id = m.id
                LEFT JOIN transcripts t ON t.asset_id = a.id
                LEFT JOIN derivations d ON d.id = (
                    SELECT id FROM derivations WHERE point_id = p.id AND state = 'succeeded'
                    ORDER BY created_at DESC, rowid DESC LIMIT 1
                )
                WHERE p.created_at <= ?
                  AND NOT EXISTS (
                    SELECT 1 FROM rediscovery_events e
                    WHERE e.point_id = p.id AND e.created_at >= ?
                      AND e.event_type IN ('shown','opened','useful','notRelated','later','resultSaved')
                  )
                ORDER BY p.created_at ASC
                LIMIT ?
                """, arguments: [cutoff, recentEventCutoff, max(limit * 4, limit)]).compactMap { row in
                    guard let uuid = UUID(uuidString: row["id"]) else { return nil }
                    return PointMapEntry(
                        point: PointSummary(id: PointID(rawValue: uuid), title: row["title"],
                                           createdAt: Date(timeIntervalSince1970: row["created_at"]),
                                           transcriptState: row["transcript_state"]),
                        content: row["content"], localeIdentifier: row["locale"]
                    )
                }
        }
        guard !candidates.isEmpty else { return [] }

        let allPoints = try await listPoints(matching: "")
        let recentIDs = Set(allPoints.filter { $0.createdAt > Date(timeIntervalSince1970: cutoff) }.map(\.id))
        let pointByID = Dictionary(uniqueKeysWithValues: allPoints.map { ($0.id, $0) })
        let records = try await embeddings(modelID: EmbeddingModelIdentity.multilingualE5Small)
        var result: [RediscoveryItem] = []
        for candidate in candidates {
            let hit = EmbeddingMath.relativeTopK(records: records, query: candidate.id, limit: 12)
                .first { recentIDs.contains($0.pointID) && $0.score >= 0.55 }
            if let hit, let related = pointByID[hit.pointID] {
                result.append(RediscoveryItem(point: candidate.point, content: candidate.content,
                                              reason: .relatedToRecent, relatedPoint: related,
                                              relatedScore: hit.score))
            } else {
                result.append(RediscoveryItem(point: candidate.point, content: candidate.content,
                                              reason: .olderThought))
            }
            if result.count == limit { break }
        }
        return result
    }

    public func recordRediscoveryFeedback(pointID: PointID, feedback: RediscoveryFeedback,
                                          context: String? = nil) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO rediscovery_events (id, point_id, event_type, context, created_at)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [UUID().uuidString, pointID.rawValue.uuidString, feedback.rawValue,
                                  context, Date().timeIntervalSince1970])
        }
    }

    public func confirmedRelation(source: PointID, target: PointID) async throws -> ConfirmedPointRelation? {
        try await writer.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT relation_type, created_at FROM confirmed_point_relations
                WHERE source_point_id = ? AND target_point_id = ?
                """, arguments: [source.rawValue.uuidString, target.rawValue.uuidString]),
                  let type = PointRelationType(rawValue: row["relation_type"]) else { return nil }
            return ConfirmedPointRelation(sourcePointID: source, targetPointID: target, type: type,
                                          createdAt: Date(timeIntervalSince1970: row["created_at"]))
        }
    }

    public func confirmRelation(source: PointID, target: PointID, type: PointRelationType) async throws {
        guard source != target else { return }
        try await writer.write { db in
            let now = Date().timeIntervalSince1970
            try db.execute(sql: """
                INSERT INTO confirmed_point_relations
                    (source_point_id, target_point_id, relation_type, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(source_point_id, target_point_id) DO UPDATE SET
                    relation_type = excluded.relation_type, updated_at = excluded.updated_at
                """, arguments: [source.rawValue.uuidString, target.rawValue.uuidString,
                                  type.rawValue, now, now])
        }
    }

    public func removeConfirmedRelation(source: PointID, target: PointID) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                DELETE FROM confirmed_point_relations
                WHERE source_point_id = ? AND target_point_id = ?
                """, arguments: [source.rawValue.uuidString, target.rawValue.uuidString])
        }
    }

    public func commitDerivedTextPoint(text: String, sourcePointIDs: [PointID],
                                       modelID: String? = nil) async throws -> PointID {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !sourcePointIDs.isEmpty else { throw PointVerseError.databaseCommitFailed }
        return try await writer.write { db in
            let pointID = PointID()
            let messageID = UUID()
            let now = Date().timeIntervalSince1970
            try db.execute(sql: "INSERT INTO points (id, created_at, updated_at) VALUES (?, ?, ?)",
                           arguments: [pointID.rawValue.uuidString, now, now])
            try db.execute(sql: """
                INSERT INTO messages (id, operation_id, point_id, sequence, role, modality, user_text, created_at, model_id)
                VALUES (?, ?, ?, 1, 'user', 'text', ?, ?, ?)
                """, arguments: [messageID.uuidString, "derived:" + messageID.uuidString,
                                  pointID.rawValue.uuidString, cleaned, now, modelID])
            try db.execute(sql: """
                INSERT INTO derivations (id, point_id, input_revision, model_id, model_sha256, prompt_version, title, state, adoption, created_at)
                VALUES (?, ?, 1, 'rule-title-v1', 'builtin', 'rule-title-v1', ?, 'succeeded', 'candidate', ?)
                """, arguments: [UUID().uuidString, pointID.rawValue.uuidString,
                                  Self.fallbackTitle(from: cleaned), now])
            for source in Set(sourcePointIDs) {
                try db.execute(sql: """
                    INSERT INTO point_origins (point_id, source_point_id, origin_type, model_id, created_at)
                    VALUES (?, ?, 'continuedThought', ?, ?)
                    """, arguments: [pointID.rawValue.uuidString, source.rawValue.uuidString, modelID, now])
                try db.execute(sql: """
                    INSERT INTO confirmed_point_relations
                        (source_point_id, target_point_id, relation_type, created_at, updated_at)
                    VALUES (?, ?, 'extend', ?, ?)
                    ON CONFLICT(source_point_id, target_point_id) DO UPDATE SET
                        relation_type = 'extend', updated_at = excluded.updated_at
                    """, arguments: [source.rawValue.uuidString, pointID.rawValue.uuidString, now, now])
            }
            try refreshSearch(pointID: pointID, db: db)
            try enqueueEmbedding(pointID: pointID, revision: 1, db: db, timestamp: now)
            return pointID
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
