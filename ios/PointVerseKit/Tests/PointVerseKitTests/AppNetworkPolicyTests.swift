import Foundation
import Testing
@testable import PointVerseKit

@Test func privacyPolicyFailsClosedAndSeparatesModelDownloadsFromContent() {
    let name = "network-policy-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    #expect(!AppNetworkPolicy.allowsCloud(defaults: defaults))
    #expect(!AppNetworkPolicy.allowsModelDownloads(defaults: defaults))
    defaults.set(true, forKey: AppNetworkPolicy.configuredKey)
    defaults.set("privacy", forKey: AppNetworkPolicy.modeKey)
    defaults.set("browser", forKey: AppNetworkPolicy.acquisitionKey)
    #expect(!AppNetworkPolicy.allowsCloud(defaults: defaults))
    #expect(!AppNetworkPolicy.allowsModelDownloads(defaults: defaults))
    defaults.set("inApp", forKey: AppNetworkPolicy.acquisitionKey)
    #expect(AppNetworkPolicy.allowsModelDownloads(defaults: defaults))
    #expect(!AppNetworkPolicy.allowsCloud(defaults: defaults))
    defaults.set("cloud", forKey: AppNetworkPolicy.modeKey)
    #expect(AppNetworkPolicy.allowsCloud(defaults: defaults))
    #expect(!AppNetworkPolicy.allowsModelDownloads(defaults: defaults))
    defaults.set(true, forKey: AppNetworkPolicy.offlineBackupKey)
    #expect(AppNetworkPolicy.allowsModelDownloads(defaults: defaults))
    defaults.set("browser", forKey: AppNetworkPolicy.acquisitionKey)
    #expect(!AppNetworkPolicy.allowsModelDownloads(defaults: defaults))
}

@Test func offlineFallbackExcludesServerAndAuthenticationErrors() {
    #expect(AppNetworkPolicy.isOfflineFailure(URLError(.notConnectedToInternet)))
    #expect(AppNetworkPolicy.isOfflineFailure(URLError(.networkConnectionLost)))
    #expect(!AppNetworkPolicy.isOfflineFailure(URLError(.timedOut)))
    #expect(!AppNetworkPolicy.isOfflineFailure(AccountAPIError.unauthorized))
    #expect(!AppNetworkPolicy.isOfflineFailure(AccountAPIError.busy))
}
