import Foundation

public enum AppUsageMode: String, CaseIterable, Sendable {
    case privacy, cloud
}

public enum LocalModelAcquisition: String, CaseIterable, Sendable {
    case browser, inApp
}

public enum AppNetworkPolicy {
    public static let modeKey = "pointverse.usageMode"
    public static let acquisitionKey = "pointverse.modelAcquisition"
    public static let configuredKey = "pointverse.modeChosen"
    public static let offlineBackupKey = "pointverse.offlineBackupEnabled"
    public static let offlineModelKey = "pointverse.offlineBackupModel"
    public static func mode(defaults: UserDefaults = .standard) -> AppUsageMode {
        AppUsageMode(rawValue: defaults.string(forKey: modeKey) ?? "") ?? .privacy
    }
    public static func acquisition(defaults: UserDefaults = .standard) -> LocalModelAcquisition {
        LocalModelAcquisition(rawValue: defaults.string(forKey: acquisitionKey) ?? "") ?? .browser
    }
    public static func allowsCloud(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: configuredKey) && mode(defaults: defaults) == .cloud
    }
    public static func allowsModelDownloads(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: configuredKey) && acquisition(defaults: defaults) == .inApp &&
            (mode(defaults: defaults) == .privacy || defaults.bool(forKey: offlineBackupKey))
    }
    public static func requireCloud() throws {
        guard allowsCloud() else { throw NetworkPolicyError.cloudDisabled }
    }
    public static func isOfflineFailure(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.notConnectedToInternet, .networkConnectionLost, .internationalRoamingOff, .dataNotAllowed].contains(error.code)
    }
}

public enum NetworkPolicyError: Error, LocalizedError, Sendable {
    case cloudDisabled, downloadsDisabled
    public var errorDescription: String? {
        switch self {
        case .cloudDisabled: "隐私版已禁止登录、云同步和网络模型。"
        case .downloadsDisabled: "当前方式不允许应用内下载，请通过浏览器下载后导入本地文件。"
        }
    }
}
