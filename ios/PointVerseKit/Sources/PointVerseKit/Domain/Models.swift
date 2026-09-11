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

public struct PointDetail: Equatable, Sendable {
    public let id: PointID
    public let title: String
    public let audioRelativePath: String
    public let durationMilliseconds: Int
    public let transcriptState: String
    public let transcriptErrorCode: String?
    public let engineText: String?
    public let userText: String?
    public let localeIdentifier: String

    public var effectiveTranscript: String? {
        let preferred = userText?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let preferred, !preferred.isEmpty { return preferred }
        let engine = engineText?.trimmingCharacters(in: .whitespacesAndNewlines)
        return engine?.isEmpty == false ? engine : nil
    }

    public init(
        id: PointID,
        title: String,
        audioRelativePath: String,
        durationMilliseconds: Int,
        transcriptState: String,
        transcriptErrorCode: String?,
        engineText: String?,
        userText: String?,
        localeIdentifier: String
    ) {
        self.id = id
        self.title = title
        self.audioRelativePath = audioRelativePath
        self.durationMilliseconds = durationMilliseconds
        self.transcriptState = transcriptState
        self.transcriptErrorCode = transcriptErrorCode
        self.engineText = engineText
        self.userText = userText
        self.localeIdentifier = localeIdentifier
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
