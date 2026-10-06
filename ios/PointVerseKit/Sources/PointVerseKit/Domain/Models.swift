import Foundation

public struct PointID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { self.init(rawValue: UUID()) }
}

public enum AssetState: String, Codable, Sendable {
    case committing, available, quarantined
}

public struct StoredAudio: Equatable, Sendable {
    public let assetID: UUID
    public let relativePath: String
    public let sha256: String
    public let byteCount: Int64
    public let durationMilliseconds: Int
    public let codec: String
    public let sampleRate: Int

    public init(
        assetID: UUID,
        relativePath: String,
        sha256: String,
        byteCount: Int64,
        durationMilliseconds: Int,
        codec: String = "aac",
        sampleRate: Int = 24_000
    ) {
        self.assetID = assetID
        self.relativePath = relativePath
        self.sha256 = sha256
        self.byteCount = byteCount
        self.durationMilliseconds = durationMilliseconds
        self.codec = codec
        self.sampleRate = sampleRate
    }
}

public struct PointImage: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let relativePath: String
    public let recognizedText: String?
    public let createdAt: Date

    public init(id: UUID, relativePath: String, recognizedText: String?, createdAt: Date) {
        self.id = id
        self.relativePath = relativePath
        self.recognizedText = recognizedText
        self.createdAt = createdAt
    }
}

public struct RecordingResult: Sendable {
    public let temporaryURL: URL
    public let durationMilliseconds: Int

    public init(temporaryURL: URL, durationMilliseconds: Int) {
        self.temporaryURL = temporaryURL
        self.durationMilliseconds = durationMilliseconds
    }
}

public struct VoiceCaptureCommand: Sendable {
    public let operationID: UUID
    public let pointID: PointID
    public let messageID: UUID
    public let audio: StoredAudio
    public let localeIdentifier: String
    public let createdAt: Date

    public init(
        operationID: UUID,
        pointID: PointID = PointID(),
        messageID: UUID = UUID(),
        audio: StoredAudio,
        localeIdentifier: String = Locale.current.identifier,
        createdAt: Date = Date()
    ) {
        self.operationID = operationID
        self.pointID = pointID
        self.messageID = messageID
        self.audio = audio
        self.localeIdentifier = localeIdentifier
        self.createdAt = createdAt
    }
}

public struct PointSummary: Identifiable, Equatable, Sendable {
    public let id: PointID
    public let title: String
    public let createdAt: Date
    public let transcriptState: String?

    public init(id: PointID, title: String, createdAt: Date, transcriptState: String?) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.transcriptState = transcriptState
    }
}

public struct PointMapEntry: Identifiable, Equatable, Sendable {
    public var id: PointID { point.id }
    public let point: PointSummary
    public let content: String
    public let localeIdentifier: String

    public init(point: PointSummary, content: String, localeIdentifier: String) {
        self.point = point
        self.content = content
        self.localeIdentifier = localeIdentifier
    }
}

public enum EmbeddingModelIdentity {
    public static let multilingualE5Small = "intfloat-multilingual-e5-small-coreml-fp32-int8"
    public static let bgeSmallZhV15 = multilingualE5Small
}

public struct PointSemanticDocument: Equatable, Sendable {
    public let pointID: PointID
    public let revision: Int
    public let text: String
    public let localeIdentifier: String

    public init(pointID: PointID, revision: Int, text: String, localeIdentifier: String) {
        self.pointID = pointID
        self.revision = revision
        self.text = text
        self.localeIdentifier = localeIdentifier
    }
}

public struct PointEmbeddingRecord: Equatable, Sendable {
    public let pointID: PointID
    public let revision: Int
    public let modelID: String
    public let vector: [Float]

    public init(pointID: PointID, revision: Int, modelID: String, vector: [Float]) {
        self.pointID = pointID
        self.revision = revision
        self.modelID = modelID
        self.vector = vector
    }
}

public enum GeographyIdentity {
    public static let semanticSphereV1 = "e5-semantic-sphere-v1"
    public static let compactSphereV2 = "e5-compact-sphere-v2"
    public static let denseSphereV3 = "e5-dense-sphere-v3"
    public static let distributedCommunitiesV4 = "e5-distributed-communities-v4"
    public static let semanticTopicsV5 = "e5-semantic-topics-v5"
    public static let relativeSemanticV6 = "e5-relative-semantic-v6"
}

public struct PointGeographyRecord: Equatable, Sendable {
    public let pointID: PointID
    public let geographyVersion: String
    public let contentRevision: Int
    public let communityID: String?
    public let latitude: Double
    public let longitude: Double
    public let altitude: Double
    public let placementConfidence: Double
    public let isPinned: Bool

    public init(
        pointID: PointID,
        geographyVersion: String,
        contentRevision: Int,
        communityID: String? = nil,
        latitude: Double,
        longitude: Double,
        altitude: Double = 0,
        placementConfidence: Double,
        isPinned: Bool = false
    ) {
        self.pointID = pointID
        self.geographyVersion = geographyVersion
        self.contentRevision = contentRevision
        self.communityID = communityID
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.placementConfidence = placementConfidence
        self.isPinned = isPinned
    }
}

public struct SimilarityHit: Equatable, Sendable {
    public let pointID: PointID
    public let score: Float

    public init(pointID: PointID, score: Float) {
        self.pointID = pointID
        self.score = score
    }
}

public struct RelatedPoint: Identifiable, Equatable, Sendable {
    public var id: PointID { point.id }
    public let point: PointSummary
    public let content: String
    public let score: Float

    public init(point: PointSummary, content: String, score: Float) {
        self.point = point
        self.content = content
        self.score = score
    }
}

public struct PointDetail: Equatable, Sendable {
    public let id: PointID
    public let title: String
    public let modality: String
    public let sourceText: String?
    public let audioRelativePath: String?
    public let durationMilliseconds: Int?
    public let transcriptState: String
    public let transcriptErrorCode: String?
    public let engineText: String?
    public let userText: String?
    public let localeIdentifier: String
    public let transcriptModelID: String?

    public var effectiveTranscript: String? {
        let preferred = userText?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let preferred, !preferred.isEmpty { return preferred }
        let engine = engineText?.trimmingCharacters(in: .whitespacesAndNewlines)
        return engine?.isEmpty == false ? engine : nil
    }

    public init(
        id: PointID,
        title: String,
        modality: String = "voice",
        sourceText: String? = nil,
        audioRelativePath: String?,
        durationMilliseconds: Int?,
        transcriptState: String,
        transcriptErrorCode: String?,
        engineText: String?,
        userText: String?,
        localeIdentifier: String,
        transcriptModelID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.modality = modality
        self.sourceText = sourceText
        self.audioRelativePath = audioRelativePath
        self.durationMilliseconds = durationMilliseconds
        self.transcriptState = transcriptState
        self.transcriptErrorCode = transcriptErrorCode
        self.engineText = engineText
        self.userText = userText
        self.localeIdentifier = localeIdentifier
        self.transcriptModelID = transcriptModelID
    }
}

public struct ConversationMessage: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let role: String
    public let text: String
    public let createdAt: Date

    public init(id: UUID, role: String, text: String, createdAt: Date) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }
}

public struct TranscriptionCandidate: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let modelID: String
    public let engineText: String
    public let userText: String?
    public let isSelected: Bool
    public let updatedAt: Date

    public var effectiveText: String {
        let edited = userText?.trimmingCharacters(in: .whitespacesAndNewlines)
        return edited?.isEmpty == false ? edited! : engineText
    }

    public init(id: UUID, modelID: String, engineText: String, userText: String?, isSelected: Bool, updatedAt: Date) {
        self.id = id; self.modelID = modelID; self.engineText = engineText
        self.userText = userText; self.isSelected = isSelected; self.updatedAt = updatedAt
    }
}

public struct DetectedNoteEvent: Codable, Equatable, Sendable {
    public let note: String
    public let startSeconds: Double
    public let durationSeconds: Double

    public init(note: String, startSeconds: Double, durationSeconds: Double) {
        self.note = note; self.startSeconds = startSeconds; self.durationSeconds = durationSeconds
    }
}

public struct AudioUnderstanding: Equatable, Sendable {
    public let durationSeconds: Double
    public let loudnessDB: Double
    public let bpm: Double?
    public let dominantPitchHz: Double?
    public let detectedNotes: [String]
    public let estimatedKey: String?
    public let noteSequence: [DetectedNoteEvent]
    public let rhythmStrength: Double
    public let semanticTags: [String]
    public let clapModelID: String?
    public let hasVoice: Bool
    public let updatedAt: Date

    public init(durationSeconds: Double, loudnessDB: Double, bpm: Double?, dominantPitchHz: Double?,
                detectedNotes: [String] = [], estimatedKey: String? = nil,
                noteSequence: [DetectedNoteEvent] = [],
                rhythmStrength: Double, semanticTags: [String], clapModelID: String?, hasVoice: Bool,
                updatedAt: Date = Date()) {
        self.durationSeconds = durationSeconds
        self.loudnessDB = loudnessDB
        self.bpm = bpm
        self.dominantPitchHz = dominantPitchHz
        self.detectedNotes = detectedNotes
        self.estimatedKey = estimatedKey
        self.noteSequence = noteSequence
        self.rhythmStrength = rhythmStrength
        self.semanticTags = semanticTags
        self.clapModelID = clapModelID
        self.hasVoice = hasVoice
        self.updatedAt = updatedAt
    }

    public var semanticText: String {
        var values = semanticTags
        if let bpm { values.append("BPM \(Int(bpm.rounded()))") }
        if let dominantPitchHz { values.append("主音高 \(Int(dominantPitchHz.rounded())) Hz") }
        if !detectedNotes.isEmpty { values.append("音符 " + detectedNotes.joined(separator: " ")) }
        if let estimatedKey { values.append("调性 " + estimatedKey) }
        values.append(String(format: "响度 %.1f dB", loudnessDB))
        return values.joined(separator: " · ")
    }
}

public struct PointDraft: Codable, Equatable, Sendable {
    public let title: String?
    public let summary: String
    public let tags: [String]
    public let nextQuestion: String?

    public init(title: String?, summary: String, tags: [String], nextQuestion: String?) throws {
        guard title.map({ $0.count <= 20 }) ?? true,
              summary.count <= 80,
              tags.count <= 3,
              tags.allSatisfy({ $0.count <= 10 }),
              nextQuestion.map({ $0.count <= 40 }) ?? true else {
            throw PointVerseError.invalidModelOutput
        }
        self.title = title
        self.summary = summary
        self.tags = tags
        self.nextQuestion = nextQuestion
    }
}
