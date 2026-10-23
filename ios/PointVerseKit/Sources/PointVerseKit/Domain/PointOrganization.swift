import Foundation

public struct PointOrganizationRecord: Identifiable, Sendable {
    public var id: PointID { entry.id }
    public let entry: PointMapEntry
    public let revision: Int
    public let hasMedia: Bool
    public let hasConversation: Bool
    public init(entry: PointMapEntry, revision: Int, hasMedia: Bool, hasConversation: Bool) {
        self.entry = entry; self.revision = revision; self.hasMedia = hasMedia; self.hasConversation = hasConversation
    }
}

public struct PointTrashRequest: Sendable {
    public let pointID: PointID
    public let reason: String
    public let expectedRevision: Int?
    public init(pointID: PointID, reason: String, expectedRevision: Int? = nil) {
        self.pointID = pointID; self.reason = reason; self.expectedRevision = expectedRevision
    }
}

public struct TrashedPoint: Identifiable, Sendable {
    public var id: PointID { point.id }
    public let point: PointSummary
    public let reason: String
    public let trashedAt: Date
}

public struct PointCleanupCandidate: Identifiable, Sendable {
    public var id: PointID { record.id }
    public let record: PointOrganizationRecord
    public let reason: String
}

/// Conservative local hints, not judgments about a person's ideas or their value.
/// Nothing is deleted or moved merely because it is short or unclassified.
public enum PointOrganization {
    public static let didChange = Notification.Name("PointVersePointAvailabilityDidChange")
    public static func cleanupCandidates(_ records: [PointOrganizationRecord]) -> [PointCleanupCandidate] {
        var seen = Set<String>()
        return records.sorted {
            $0.entry.point.createdAt == $1.entry.point.createdAt
                ? $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
                : $0.entry.point.createdAt < $1.entry.point.createdAt
        }.compactMap { record in
            guard !record.hasMedia, !record.hasConversation else { return nil }
            let content = record.entry.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = record.entry.point.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if content.isEmpty && title.isEmpty { return .init(record: record, reason: "没有文字或附件，请确认是否需要保留") }
            // Exact text AND title only. No fuzzy similarity-based deletion.
            let key = title + "\u{0}" + content
            if !seen.insert(key).inserted { return .init(record: record, reason: "文字与标题完全相同；保留了较早的一条，请确认重复记录是否仍有意义") }
            return nil
        }
    }
}
