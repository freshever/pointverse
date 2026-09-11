import OSLog

public enum PointVerseLog {
    public static let capture = Logger(subsystem: "com.pointverse.poc", category: "capture")
    public static let storage = Logger(subsystem: "com.pointverse.poc", category: "storage")
    public static let database = Logger(subsystem: "com.pointverse.poc", category: "database")
    public static let transcription = Logger(subsystem: "com.pointverse.poc", category: "transcription")
}
