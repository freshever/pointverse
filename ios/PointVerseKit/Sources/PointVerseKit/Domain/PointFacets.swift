import Foundation

public enum PointFacetDimension: String, CaseIterable, Codable, Hashable, Sendable {
    case domain, topic, project, expression
    public var title: String {
        switch self { case .domain: "知识领域"; case .topic: "主题"; case .project: "项目"; case .expression: "表达性质" }
    }
}

public struct PointFacetTerm: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let parentID: String?
    public let dimension: PointFacetDimension
    public let keywords: [String]
}

public struct PointFacetOverride: Sendable {
    public let pointID: PointID
    public let dimension: PointFacetDimension
    /// An empty manual set is meaningful: do not reinsert automatic suggestions.
    public let values: [String]
    public init(pointID: PointID, dimension: PointFacetDimension, values: [String]) {
        self.pointID = pointID; self.dimension = dimension; self.values = values
    }
}

public struct PointFacetClassification: Sendable {
    public let pointID: PointID
    public let values: [PointFacetDimension: Set<String>]
    public let manualDimensions: Set<PointFacetDimension>
    public let modelDimensions: Set<PointFacetDimension>
}

/// LCC outline domains plus independent, app-authored facets.
/// Rule matches are suggestions, never calibrated probabilities or AI judgments.
public enum PointFacetEngine {
    public static let version = "facets-lcc-rules-v2"
    public static let unassigned = "__unassigned"
    public static let terms: [PointFacetTerm] = LCCCatalog.facetTerms + localTerms
    private static let localTerms: [PointFacetTerm] = [
        .init(id: "technology", title: "科学与技术", parentID: nil, dimension: .domain, keywords: []),
        .init(id: "computing", title: "计算机", parentID: "technology", dimension: .domain, keywords: ["计算机", "computer", "软件", "software"]),
        .init(id: "software", title: "软件工程", parentID: "computing", dimension: .domain, keywords: ["Swift", "编程", "代码", "iOS", "程序", "数据库", "编译", "并发", "内存", "programming", "database"]),
        .init(id: "ai", title: "人工智能", parentID: "computing", dimension: .domain, keywords: ["人工智能", "大模型", "embedding", "Core ML", "机器学习", "神经网络", "语音识别", "AI"]),
        .init(id: "nature", title: "自然科学", parentID: "technology", dimension: .domain, keywords: ["物理", "天文", "黑洞", "化学", "生物学", "physics", "astronomy"]),
        .init(id: "health", title: "健康与运动", parentID: nil, dimension: .domain, keywords: ["跑步", "健康", "睡眠", "运动", "医疗", "running", "health", "exercise"]),
        .init(id: "humanities", title: "人文与社会", parentID: nil, dimension: .domain, keywords: ["哲学", "历史", "心理学", "社会", "经济", "金融", "philosophy", "history", "economics"]),
        .init(id: "arts", title: "艺术与创作", parentID: nil, dimension: .domain, keywords: ["音乐", "小说", "绘画", "诗歌", "写作", "摄影", "music", "novel", "photography"]),
        .init(id: "life", title: "生活与实践", parentID: nil, dimension: .domain, keywords: ["烹饪", "旅行", "装修", "园艺", "做饭", "cooking", "travel", "gardening"]),
        .init(id: "memory-management", title: "内存管理", parentID: nil, dimension: .topic, keywords: ["内存", "循环引用", "retain cycle", "memory management"]),
        .init(id: "concurrency", title: "并发与同步", parentID: nil, dimension: .topic, keywords: ["并发", "线程", "死锁", "concurrency", "thread", "deadlock"]),
        .init(id: "database", title: "数据库", parentID: nil, dimension: .topic, keywords: ["数据库", "SQLite", "database", "索引"]),
        .init(id: "embedding", title: "语义向量", parentID: nil, dimension: .topic, keywords: ["embedding", "语义向量", "向量检索"]),
        .init(id: "speech", title: "语音转写", parentID: nil, dimension: .topic, keywords: ["语音转写", "语音识别", "录音转文字", "speech recognition", "transcription"]),
        .init(id: "interaction", title: "交互与体验", parentID: nil, dimension: .topic, keywords: ["交互", "用户体验", "使用门槛", "等待太久", "usability", "user experience"]),
        .init(id: "running", title: "跑步", parentID: nil, dimension: .topic, keywords: ["跑步", "running", "马拉松", "marathon"]),
        .init(id: "sleep", title: "睡眠", parentID: nil, dimension: .topic, keywords: ["睡眠", "失眠", "sleep", "insomnia"]),
        .init(id: "writing", title: "写作", parentID: nil, dimension: .topic, keywords: ["写作", "小说", "诗歌", "writing", "novel"]),
        .init(id: "question", title: "问题", parentID: nil, dimension: .expression, keywords: ["为什么", "如何", "怎么办", "能不能", "？", "?", "how", "why"]),
        .init(id: "hypothesis", title: "设想", parentID: nil, dimension: .expression, keywords: ["也许", "假设", "能不能", "突然想到", "perhaps", "what if"]),
        .init(id: "plan", title: "计划", parentID: nil, dimension: .expression, keywords: ["计划", "打算", "下一步", "准备尝试", "I plan", "next step"]),
        .init(id: "experience", title: "经验与观察", parentID: nil, dimension: .expression, keywords: ["我发现", "亲测", "试过", "尝试后", "I noticed", "I tried"]),
        .init(id: "summary", title: "总结与方法", parentID: nil, dimension: .expression, keywords: ["总结", "步骤", "方法是", "结论", "summary", "procedure"]),
        .init(id: "feeling", title: "感受", parentID: nil, dimension: .expression, keywords: ["我感到", "我觉得", "我的感受", "I feel"])
    ]

    public static func isLegacyDomain(_ id: String) -> Bool {
        localTerms.contains { $0.id == id && $0.dimension == .domain }
    }
    public static func title(_ id: String) -> String {
        if let theme = PointThemeClassifier.themeFromID(id) { return theme }
        let name = terms.first { $0.id == id }?.title ?? id
        return isLegacyDomain(id) ? "旧自定义 · " + name : name
    }

    public static func belongs(_ value: String, to termID: String) -> Bool {
        var current: String? = value
        while let id = current {
            if id == termID { return true }
            current = terms.first { $0.id == id }?.parentID
        }
        return false
    }

    public static func classify(_ entry: PointMapEntry, overrides: [PointFacetOverride] = [],
                                review: LCCClassificationReview? = nil) -> PointFacetClassification {
        let text = entry.point.title + "\n" + entry.content
        var result: [PointFacetDimension: Set<String>] = [:]
        for term in terms where term.keywords.contains(where: { matches(text, keyword: $0) }) {
            guard term.dimension != .domain || !isLegacyDomain(term.id) else { continue }
            result[term.dimension, default: []].insert(term.id)
        }
        // Keep only the most specific matching domain values; parent membership
        // is derived when browsing, rather than counted as duplicate assignments.
        let domains = result[.domain] ?? []
        result[.domain] = Set(domains.filter { parent in !domains.contains { $0 != parent && belongs($0, to: parent) } })
        let manual = overrides.filter { $0.pointID == entry.id }
        var modelDimensions = Set<PointFacetDimension>()
        if let review, review.isCurrent(for: entry), let theme = review.theme,
           let mapped = try? PointThemeClassifier.parse(theme), let domain = mapped.domainID,
           review.decision.status == .suggested, review.decision.ids == [domain],
           !manual.contains(where: { $0.dimension == .domain }) {
            result[.domain] = [domain]
            modelDimensions.insert(.domain)
        }
        if let review, review.isCurrent(for: entry), let theme = review.theme,
           PointThemeClassifier.isValidTheme(theme), !manual.contains(where: { $0.dimension == .topic }) {
            result[.topic, default: []].insert(PointThemeClassifier.topicID(theme))
            modelDimensions.insert(.topic)
        }
        for item in manual { result[item.dimension] = Set(item.values) }
        return .init(pointID: entry.id, values: result, manualDimensions: Set(manual.map(\.dimension)), modelDimensions: modelDimensions)
    }

    /// OR within one facet; AND across facets. Different views never rewrite assignments.
    public static func matches(_ classification: PointFacetClassification, filters: [PointFacetDimension: Set<String>]) -> Bool {
        filters.allSatisfy { dimension, selected in
            let values = classification.values[dimension] ?? []
            return selected.isEmpty || (values.isEmpty && selected.contains(unassigned)) || values.contains { value in
                selected.contains { dimension == .domain ? belongs(value, to: $0) : value == $0 }
            }
        }
    }

    private static func matches(_ text: String, keyword: String) -> Bool {
        if keyword.unicodeScalars.allSatisfy({ $0.isASCII && ($0.properties.isAlphabetic || $0 == " ") }) {
            let pattern = "(?i)(?<![a-z0-9_])" + NSRegularExpression.escapedPattern(for: keyword) + "(?![a-z0-9_])"
            return text.range(of: pattern, options: .regularExpression) != nil
        }
        return text.localizedCaseInsensitiveContains(keyword)
    }
}
