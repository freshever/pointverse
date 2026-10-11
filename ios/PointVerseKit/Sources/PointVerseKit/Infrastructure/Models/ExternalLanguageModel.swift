import Foundation

public enum ExternalLanguageModelKind: String, Codable, Sendable {
    case openAICompatible
    case localGGUF
}

public enum ExternalModelCapability: String, Codable, CaseIterable, Sendable {
    case language
    case imageGeneration
    case embedding
    case vision
    case speech
    case audioUnderstanding

    public var displayName: String {
        switch self {
        case .language: return "对话与整理"
        case .imageGeneration: return "图片生成"
        case .embedding: return "语义向量"
        case .vision: return "图片理解"
        case .speech: return "语音转写"
        case .audioUnderstanding: return "音乐与声音"
        }
    }
}

public enum ExternalLanguageModelProvider: String, Codable, CaseIterable, Sendable {
    case openRouter
    case groq
    case openAI
    case custom

    public var displayName: String {
        switch self {
        case .openRouter: return "OpenRouter"
        case .groq: return "Groq"
        case .openAI: return "OpenAI"
        case .custom: return "自定义"
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .groq: return "https://api.groq.com/openai/v1"
        case .openAI: return "https://api.openai.com/v1"
        case .custom: return ""
        }
    }

    public var suggestedModel: String {
        switch self {
        case .openRouter: return "openrouter/free"
        case .groq: return ""
        case .openAI: return ""
        case .custom: return ""
        }
    }
}

public struct ExternalLanguageModel: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var kind: ExternalLanguageModelKind
    public var provider: ExternalLanguageModelProvider?
    public var baseURL: String?
    public var remoteModel: String?
    public var localPath: String?
    /// Optional keeps configurations created before capability routing decodable.
    /// Legacy network models are treated as language-only models.
    public var capabilities: [ExternalModelCapability]?

    public init(id: UUID = UUID(), name: String, kind: ExternalLanguageModelKind,
                provider: ExternalLanguageModelProvider? = nil,
                baseURL: String? = nil, remoteModel: String? = nil, localPath: String? = nil,
                capabilities: [ExternalModelCapability]? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.provider = provider
        self.baseURL = baseURL
        self.remoteModel = remoteModel
        self.localPath = localPath
        self.capabilities = capabilities
    }

    public var selectionID: String { "external:\(id.uuidString)" }
    public var supportedCapabilities: [ExternalModelCapability] { capabilities ?? [.language] }
    public func supports(_ capability: ExternalModelCapability) -> Bool {
        supportedCapabilities.contains(capability)
    }
}

public enum ExternalModelCapabilitySelectionStore {
    public static func defaultsKey(for capability: ExternalModelCapability) -> String {
        "selectedExternalModel.\(capability.rawValue)"
    }

    public static func selectedID(for capability: ExternalModelCapability,
                                  defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: defaultsKey(for: capability))
    }

    public static func select(_ modelID: String?, for capability: ExternalModelCapability,
                              defaults: UserDefaults = .standard) {
        defaults.set(modelID, forKey: defaultsKey(for: capability))
    }
}

public enum ExternalModelPrivacyApprovalStore {
    private static let defaultsKey = "approvedExternalNetworkModelIDs"

    public static func isApproved(_ modelID: UUID, defaults: UserDefaults = .standard) -> Bool {
        Set(defaults.stringArray(forKey: defaultsKey) ?? []).contains(modelID.uuidString)
    }

    public static func approve(_ modelID: UUID, defaults: UserDefaults = .standard) {
        var values = Set(defaults.stringArray(forKey: defaultsKey) ?? [])
        values.insert(modelID.uuidString)
        defaults.set(Array(values), forKey: defaultsKey)
    }

    public static func revoke(_ modelID: UUID, defaults: UserDefaults = .standard) {
        var values = Set(defaults.stringArray(forKey: defaultsKey) ?? [])
        values.remove(modelID.uuidString)
        defaults.set(Array(values), forKey: defaultsKey)
    }
}

public enum ExternalLanguageModelStore {
    public static let defaultsKey = "externalLanguageModels"

    public static func load(defaults: UserDefaults = .standard) -> [ExternalLanguageModel] {
        guard let data = defaults.data(forKey: defaultsKey),
              let models = try? JSONDecoder().decode([ExternalLanguageModel].self, from: data) else { return [] }
        return models
    }

    public static func save(_ models: [ExternalLanguageModel], defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(models) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    public static func selected(defaults: UserDefaults = .standard) -> ExternalLanguageModel? {
        let selectedID = ModelSelection.selectedLanguageModelID(defaults: defaults)
        return load(defaults: defaults).first { $0.selectionID == selectedID }
    }
}
