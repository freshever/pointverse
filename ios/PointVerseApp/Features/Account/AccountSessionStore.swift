import AuthenticationServices
import GoogleSignIn
import PointVerseKit
import Security
import SwiftUI

@MainActor
final class AccountSessionStore: ObservableObject {
    @Published private(set) var session: AccountSession?
    @Published private(set) var user: AccountUser?
    @Published private(set) var providers: AccountProviders?
    @Published private(set) var isBusy = false
    @Published private(set) var isSyncing = false
    @Published private(set) var isVerified = false
    @Published var errorMessage: String?
    let serverAddress: String
    private var appleCoordinator: AppleLoginCoordinator?
    private static let productionServiceURL = URL(string: "https://dianjie.org")!

    init() {
        serverAddress = Self.productionServiceURL.absoluteString
        guard AppNetworkPolicy.allowsCloud() else { return }
        do {
            if let stored = try AccountKeychain.read(), stored.origin == serverAddress, stored.session.expiresAt > Date() {
                session = stored.session
                user = stored.session.user
            } else { try AccountKeychain.remove() }
        } catch { errorMessage = "无法读取安全登录信息，请稍后重试。" }
    }
    var registrationURL: URL { Self.productionServiceURL.appendingPathComponent("account/") }
    var serviceURL: URL { Self.productionServiceURL }
    var googleAvailable: Bool {
        providers?.google == true && googleClientID != nil && googleServerID != nil && googleCallbackConfigured
    }
    var appleAvailable: Bool { providers?.apple == true && appleCapabilityConfigured }
    private var googleClientID: String? { setting("GIDClientID") }
    private var googleServerID: String? { setting("GIDServerClientID") }
    private var appleCapabilityConfigured: Bool { Bundle.main.object(forInfoDictionaryKey: "PointVerseAppleSignInEnabled") as? Bool == true }
    private var googleCallbackConfigured: Bool {
        guard let id = googleClientID else { return false }
        let expected = id.split(separator: ".").reversed().joined(separator: ".")
        let entries = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        return entries.contains { ($0["CFBundleURLSchemes"] as? [String] ?? []).contains(expected) }
    }
    private func setting(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }
    func api() throws -> AccountAPI {
        try AppNetworkPolicy.requireCloud()
        return try AccountAPI(baseURL: Self.productionServiceURL)
    }
    func applyUsageMode() {
        guard UserDefaults.standard.bool(forKey: AppNetworkPolicy.configuredKey) else { return }
        if !AppNetworkPolicy.allowsCloud() {
            AccountAPI.cancelAllRequests()
            try? AccountKeychain.remove()
            session = nil; user = nil; providers = nil; isVerified = false
        } else if session == nil,
                  let stored = try? AccountKeychain.read(), stored.origin == serverAddress,
                  stored.session.expiresAt > Date() {
            session = stored.session
            user = stored.session.user
        }
    }
    func refresh() async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            if let session, session.expiresAt <= Date() { try clear() }
            let api = try api()
            providers = try await api.providers()
            if let session {
                guard session.expiresAt > Date() else { try clear(); return }
                do { user = try await api.currentUser(token: session.accessToken); isVerified = true }
                catch AccountAPIError.unauthorized { try clear(); errorMessage = AccountAPIError.unauthorized.localizedDescription }
            }
        } catch { show(error) }
    }
    func loginEmail(email: String, password: String) async {
        guard !isBusy else { return }
        guard !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !password.isEmpty else {
            errorMessage = "请输入邮箱和密码。"; return
        }
        isBusy = true; errorMessage = nil
        defer { isBusy = false }
        do {
            let client = try api()
            let value = try await client.loginEmail(email: email, password: password)
            do { try save(value) }
            catch {
                try? await client.logout(token: value.accessToken)
                throw AccountAPIError.secureStorage
            }
        } catch { show(error) }
    }
    func loginGoogle() async {
        guard !isBusy, googleAvailable, let clientID = googleClientID, let serverID = googleServerID else { return }
        isBusy = true; errorMessage = nil
        defer { isBusy = false }
        do {
            guard let presenter = Self.presenter() else { throw AccountAPIError.invalidResponse }
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID, serverClientID: serverID)
            // A fresh authorization avoids reusing a token already exchanged with our backend.
            GIDSignIn.sharedInstance.signOut()
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
            guard let idToken = result.user.idToken?.tokenString else { throw AccountAPIError.invalidCredential }
            try save(try await api().login(provider: "google", idToken: idToken))
        } catch {
            let ns = error as NSError
            if !(ns.domain == kGIDSignInErrorDomain && ns.code == GIDSignInError.canceled.rawValue) { show(error) }
        }
    }
    func loginApple() async {
        guard !isBusy, appleAvailable else { return }
        isBusy = true; errorMessage = nil
        defer { isBusy = false; appleCoordinator = nil }
        do {
            let api = try api()
            let challenge = try await api.challenge()
            guard challenge.expiresAt > Date(), let window = Self.presenter()?.view.window else { throw AccountAPIError.invalidResponse }
            let coordinator = AppleLoginCoordinator()
            appleCoordinator = coordinator
            let token = try await coordinator.signIn(nonce: challenge.nonce, window: window)
            try save(try await api.login(provider: "apple", idToken: token, challengeID: challenge.challengeId))
        } catch {
            if (error as NSError).domain != ASAuthorizationError.errorDomain || (error as NSError).code != ASAuthorizationError.canceled.rawValue { show(error) }
        }
    }
    func beginSync() -> Bool {
        guard !isBusy, !isSyncing, let session, session.expiresAt > Date() else { errorMessage = AccountAPIError.unauthorized.localizedDescription; return false }
        isSyncing = true; return true
    }
    func endSync() { isSyncing = false }
    func logout() async {
        guard !isBusy, !isSyncing, let session else { return }
        isBusy = true; errorMessage = nil
        defer { isBusy = false }
        do {
            try await api().logout(token: session.accessToken)
            try clear()
            GIDSignIn.sharedInstance.signOut()
        } catch { errorMessage = "暂时无法退出，请联网后重试。" }
    }
    private func save(_ value: AccountSession) throws {
        try AppNetworkPolicy.requireCloud()
        try AccountKeychain.write(.init(origin: serverAddress, session: value))
        session = value; user = value.user; isVerified = true
    }
    private func clear() throws {
        try AccountKeychain.remove()
        session = nil; user = nil; isVerified = false
    }
    private func show(_ error: Error) {
        isVerified = false
        errorMessage = (error as? AccountAPIError)?.localizedDescription ?? "无法连接账户服务，请检查网络后重试。"
    }
    private static func presenter() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        var controller = scenes.first(where: { $0.activationState == .foregroundActive })?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let presented = controller?.presentedViewController { controller = presented }
        return controller
    }
}

private enum AccountKeychain {
    struct Stored: Codable { let origin: String; let session: AccountSession }
    static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "org.dianjie.pv.account", kSecAttrAccount as String: "session"] }
    static func read() throws -> Stored? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw AccountAPIError.invalidResponse }
        return try JSONDecoder().decode(Stored.self, from: data)
    }
    static func write(_ value: Stored) throws {
        let data = try JSONEncoder().encode(value)
        let update = [kSecValueData as String: data] as CFDictionary
        let status = SecItemUpdate(query as CFDictionary, update)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw AccountAPIError.invalidResponse }
        } else if status != errSecSuccess { throw AccountAPIError.invalidResponse }
    }
    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AccountAPIError.invalidResponse }
    }
}
