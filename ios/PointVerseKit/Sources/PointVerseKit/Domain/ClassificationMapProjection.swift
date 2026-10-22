import Foundation

/// Transient view projection only. Never rewrites persisted semantic coordinates.
public enum ClassificationMapProjection {
    public static let didChange = Notification.Name("PointVerseClassificationDidChange")
    public enum PlanetDirection: String, CaseIterable, Sendable {
        case technology, science, life, wellbeing, society, creation, pending
        public var title: String {
            switch self {
            case .technology: "技术与工具"; case .science: "科学探索"; case .life: "日常生活"
            case .wellbeing: "身心与关系"; case .society: "社会与世界"; case .creation: "创作与表达"; case .pending: "待整理"
            }
        }
        public var systemID: String {
            switch self {
            case .technology, .science, .creation: "exploration"
            case .life, .wellbeing: "living"
            case .society: "society"
            case .pending: "pending"
            }
        }
        public var systemName: String {
            switch self {
            case .technology, .science, .creation: "探索与创造"
            case .life, .wellbeing: "生活与成长"
            case .society: "社会与世界"
            case .pending: "待整理"
            }
        }
    }
    /// UI grouping, not a replacement for the original LCC assignments.
    public static func direction(for domain: String?) -> PlanetDirection {
        guard let domain else { return .pending }
        let legacy: [String: PlanetDirection] = ["technology": .technology, "computing": .technology, "software": .technology,
            "ai": .technology, "nature": .science, "health": .wellbeing, "humanities": .society, "arts": .creation, "life": .life]
        if let value = legacy[domain] { return value }
        guard let code = LCCCatalog.byID[domain]?.code else { return .pending }
        if code.hasPrefix("QA75") || code.hasPrefix("QA76") || code.hasPrefix("Z") { return .technology }
        if code == "GV" || code == "BF" || code.hasPrefix("R") || code.hasPrefix("L") { return .wellbeing }
        if code == "AM" || code == "BH" || code == "TR" || code == "TT" || ["M", "N", "P"].contains(String(code.prefix(1))) { return .creation }
        if ["GA", "GB", "GC", "GE"].contains(code) || code.hasPrefix("Q") { return .science }
        if ["GF", "GN", "GR", "GT"].contains(code) || ["B", "C", "D", "E", "F", "H", "J", "K", "U", "V"].contains(String(code.prefix(1))) { return .society }
        if code == "TX" || code == "TH" || code.hasPrefix("S") || code.hasPrefix("G") { return .life }
        if code.hasPrefix("T") { return .technology }
        return .pending
    }
    public struct Region: Codable, Sendable {
        public let rootID: String
        public let rootName: String
        public let planetID: String
        public let planetName: String
        public let provinceName: String
        public let provinceID: String?
        public let topicName: String?
        public var communityID: String {
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            return "classification:" + ((try? encoder.encode(self)) ?? Data()).base64EncodedString()
        }
        public var provinceCommunityID: String {
            Region(rootID: rootID, rootName: rootName, planetID: planetID, planetName: planetName,
                   provinceName: provinceName, provinceID: provinceID, topicName: nil).communityID
        }
    }
    public static func region(_ communityID: String?) -> Region? {
        guard let id = communityID, id.hasPrefix("classification:"),
              let data = Data(base64Encoded: String(id.dropFirst(15))) else { return nil }
        return try? JSONDecoder().decode(Region.self, from: data)
    }
    public static func make(entries: [PointMapEntry], geographies: [PointGeographyRecord],
                            overrides: [PointFacetOverride], reviews: [LCCClassificationReview]) -> [PointGeographyRecord] {
        let old = Dictionary(uniqueKeysWithValues: geographies.map { ($0.pointID, $0) })
        let byID = Dictionary(uniqueKeysWithValues: reviews.map { ($0.pointID, $0) })
        let manual = Dictionary(grouping: overrides, by: \.pointID)
        // Preserve the original map until there is classification information.
        guard entries.contains(where: { byID[$0.id]?.isCurrent(for: $0) == true && byID[$0.id]?.theme != nil })
                || overrides.contains(where: { $0.dimension == .domain || $0.dimension == .topic }) else { return geographies }
        return entries.map { entry in
            let classification = PointFacetEngine.classify(entry, overrides: manual[entry.id] ?? [], review: byID[entry.id])
            func depth(_ id: String) -> Int {
                var value = LCCCatalog.byID[id]; var count = 0
                while let node = value { count += 1; value = node.parentID.flatMap { LCCCatalog.byID[$0] } }
                return count
            }
            let domain = (classification.values[.domain] ?? []).sorted {
                depth($0) == depth($1) ? $0 < $1 : depth($0) > depth($1)
            }.first
            let topics = classification.values[.topic] ?? []
            let modelTheme = byID[entry.id].flatMap { $0.isCurrent(for: entry) ? $0.theme : nil }
            let topic = modelTheme.flatMap { topics.contains(PointThemeClassifier.topicID($0)) ? $0 : nil }
                ?? topics.sorted().first.map { PointFacetEngine.title($0) }
            let bucket = direction(for: domain)
            let metadata = Region(rootID: "direction:" + bucket.systemID, rootName: bucket.systemName,
                planetID: "direction:" + bucket.rawValue, planetName: bucket.title,
                provinceName: domain.map { LCCCatalog.friendlyTitle($0) } ?? "未匹配目录",
                provinceID: domain ?? "unmapped", topicName: topic)
            let previous = old[entry.id]
            let seed = entry.id.rawValue.uuidString.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
            let latitude = Double(seed % 14000) / 100 - 70
            let longitude = Double((seed / 14000) % 36000) / 100 - 180
            return .init(pointID: entry.id, geographyVersion: "classification-view-v2", contentRevision: previous?.contentRevision ?? 1,
                communityID: metadata.communityID, latitude: previous?.latitude ?? latitude, longitude: previous?.longitude ?? longitude,
                altitude: previous?.altitude ?? 0, placementConfidence: previous?.placementConfidence ?? 0,
                isPinned: previous?.isPinned ?? false)
        }
    }
}
