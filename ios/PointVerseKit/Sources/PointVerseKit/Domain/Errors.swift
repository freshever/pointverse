import Foundation

public enum PointVerseError: String, Error, Codable, Sendable {
    case microphonePermissionDenied
    case audioSessionUnavailable
    case recordingInterrupted
    case audioCommitFailed
    case databaseCommitFailed
    case insufficientDiskSpace
    case modelNotInstalled
    case modelChecksumMismatch
    case modelLoadFailed
    case audioDecodeFailed
    case transcriptionFailed
    case onDeviceRecognitionUnavailable
    case generationFailed
    case invalidModelOutput
    case cancelled
}
