import Foundation

public struct AccountIdentity: Codable, Sendable {
    public let provider: String
    public let email: String?
    public let emailVerified: Bool
}
public struct AccountUser: Codable, Sendable {
    public let id: String
    public let displayName: String
    public let createdAt: Date
    public let identities: [AccountIdentity]
}
public struct AccountSession: Codable, Sendable {
    public let accessToken: String
    public let tokenType: String
    public let expiresAt: Date
    public let user: AccountUser
}
public struct AccountProviders: Decodable, Sendable {
    public let google: Bool
    public let apple: Bool
}
public struct AppleLoginChallenge: Decodable, Sendable {
    public let challengeId: String
    public let nonce: String
    public let expiresAt: Date
}
public enum AccountAPIError: Error, LocalizedError, Sendable {
    case invalidAddress, unauthorized, unavailable, invalidCredential, rateLimited, invalidResponse, invalidEmailCredentials, invalidEmail, busy, secureStorage
    public var errorDescription: String? {
        switch self {
        case .invalidEmailCredentials: "邮箱或密码不正确，请重新输入。"
        case .invalidEmail: "请输入有效的邮箱地址。"
        case .busy: "账户服务繁忙，请稍后重试。"
        case .secureStorage: "无法安全保存登录信息，请重试。"
        case .invalidAddress: "请输入有效的 HTTPS 服务地址。"
        case .unauthorized: "登录已过期，请重新登录。"
        case .unavailable: "登录暂未开放，请稍后再试。"
        case .invalidCredential: "本次授权未能完成，请重新登录。"
        case .rateLimited: "操作较频繁，请稍后再试。"
        case .invalidResponse: "账户服务暂时不可用，请稍后重试。"
        }
    }
}

public actor AccountAPI {
    let baseURL: URL
    let session: URLSession
    let allowsNetwork: @Sendable () -> Bool
    public init(baseURL: URL, allowLocalHTTP: Bool = false, session: URLSession? = nil,
                allowsNetwork: @escaping @Sendable () -> Bool = { AppNetworkPolicy.allowsCloud() }) throws {
        guard Self.isAllowed(baseURL, allowLocalHTTP: allowLocalHTTP) else { throw AccountAPIError.invalidAddress }
        self.baseURL = baseURL
        self.allowsNetwork = allowsNetwork
        if let session { self.session = session } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 600
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration, delegate: AccountRedirectGuard(), delegateQueue: nil)
        }
        AccountNetworkSessions.shared.register(self.session)
    }
    deinit { session.invalidateAndCancel() }
    public nonisolated static func cancelAllRequests() { AccountNetworkSessions.shared.cancelAll() }
    public nonisolated static func isAllowed(_ url: URL, allowLocalHTTP: Bool) -> Bool {
        guard let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return false }
        if url.scheme == "https" { return true }
        guard allowLocalHTTP, url.scheme == "http" else { return false }
        if host == "localhost" || host == "127.0.0.1" || host == "[::1]" || host == "::1" || host.hasSuffix(".local") { return true }
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else { return false }
        let parts = components.compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        return parts[0] == 10 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && (16...31).contains(parts[1]))
    }
    public nonisolated static func serviceURL(from address: String) -> URL? {
        guard var url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)), isAllowed(url, allowLocalHTTP: true) else { return nil }
        if url.path == "/account/" || url.path == "/account" { url = url.deletingLastPathComponent() }
        return url
    }
    public func loginEmail(email: String, password: String) async throws -> AccountSession {
        let body = ["email": email.trimmingCharacters(in: .whitespacesAndNewlines), "password": password]
        let data = try await request("v1/auth/email/login", method: "POST", body: JSONEncoder().encode(body))
        return try decodeSession(data)
    }
    private func decodeSession(_ data: Data) throws -> AccountSession {
        let result = try Self.decoder().decode(AccountSession.self, from: data)
        guard result.tokenType == "Bearer", !result.accessToken.isEmpty, result.expiresAt > Date() else { throw AccountAPIError.invalidResponse }
        return result
    }
    public func providers() async throws -> AccountProviders { try await get("v1/auth/providers") }
    public func currentUser(token: String) async throws -> AccountUser { try await get("v1/auth/me", token: token) }
    public func challenge() async throws -> AppleLoginChallenge {
        let data = try await request("v1/auth/apple/challenge", method: "POST")
        return try Self.decoder().decode(AppleLoginChallenge.self, from: data)
    }
    public func login(provider: String, idToken: String, challengeID: String? = nil) async throws -> AccountSession {
        guard provider == "apple" || provider == "google" else { throw AccountAPIError.invalidCredential }
        var body = ["id_token": idToken]
        if let challengeID { body["challenge_id"] = challengeID }
        let data = try await request("v1/auth/" + provider, method: "POST", body: JSONEncoder().encode(body))
        return try decodeSession(data)
    }
    public func logout(token: String) async throws { _ = try await request("v1/auth/logout", method: "POST", token: token) }
    private func get<T: Decodable>(_ path: String, token: String? = nil) async throws -> T {
        let data = try await request(path, method: "GET", token: token)
        return try Self.decoder().decode(T.self, from: data)
    }
    func request(_ path: String, method: String, body: Data? = nil, token: String? = nil, query: [URLQueryItem] = []) async throws -> Data {
        guard allowsNetwork() else { throw NetworkPolicyError.cloudDisabled }
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        try checkResponse(data, response: response, token: token)
        return data
    }
    func checkResponse(_ data: Data, response: URLResponse, token: String?) throws {
        guard let response = response as? HTTPURLResponse else { throw AccountAPIError.invalidResponse }
        let errorCode = (try? JSONDecoder().decode(AccountErrorEnvelope.self, from: data))?.error.code
        switch response.statusCode {
        case 200..<300: return
        case 400 where errorCode == "invalid_email": throw AccountAPIError.invalidEmail
        case 401 where errorCode == "invalid_credentials" && token == nil: throw AccountAPIError.invalidEmailCredentials
        case 401: throw token == nil ? AccountAPIError.invalidCredential : AccountAPIError.unauthorized
        case 409 where errorCode == "missing_assets": throw CloudSyncError.missingAssets
        case 413 where errorCode == "storage_quota_exceeded": throw CloudSyncError.quota
        case 413: throw CloudSyncError.tooLarge
        case 400 where errorCode == "asset_checksum_mismatch": throw CloudSyncError.checksum
        case 429: throw AccountAPIError.rateLimited
        case 503 where errorCode == "auth_busy": throw AccountAPIError.busy
        case 503: throw AccountAPIError.unavailable
        default: throw AccountAPIError.invalidResponse
        }
    }
    public nonisolated static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: value) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid account date"))
        }
        return decoder
    }
}
private final class AccountNetworkSessions: @unchecked Sendable {
    static let shared = AccountNetworkSessions()
    private final class Entry { weak var session: URLSession?; init(_ session: URLSession) { self.session = session } }
    private let lock = NSLock()
    private var entries: [Entry] = []
    func register(_ session: URLSession) {
        lock.lock()
        entries.removeAll { $0.session == nil }
        entries.append(Entry(session))
        lock.unlock()
    }
    func cancelAll() {
        lock.lock()
        let sessions = entries.compactMap(\.session)
        entries.removeAll()
        lock.unlock()
        sessions.forEach { $0.invalidateAndCancel() }
    }
}

private final class AccountRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private struct AccountErrorEnvelope: Decodable {
    struct Detail: Decodable { let code: String }
    let error: Detail
}
