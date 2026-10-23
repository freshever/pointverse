import Foundation
import XCTest
@testable import PointVerseKit

final class AccountAPITests: XCTestCase {
    func testAddressRestrictions() {
        for address in ["https://api.example.com", "http://127.0.0.1:8080", "http://192.168.3.4:8080", "http://dev.local:8080"] {
            XCTAssertTrue(AccountAPI.isAllowed(URL(string: address)!, allowLocalHTTP: true), address)
        }
        for address in ["http://api.example.com", "https://user:password@example.com", "https://example.com?token=secret", "http://foo.10.1.2.3", "http://192.168.0.1.evil.example", "file:///tmp/account"] {
            XCTAssertFalse(AccountAPI.isAllowed(URL(string: address)!, allowLocalHTTP: true), address)
        }
        XCTAssertFalse(AccountAPI.isAllowed(URL(string: "http://127.0.0.1:8080")!, allowLocalHTTP: false))
    }
    func testServerDatesAndKeychainRoundTrip() throws {
        for date in ["2026-10-22T14:00:00Z", "2026-10-22T14:00:00.123456789Z"] {
            let data = Data("""
            {"access_token":"secret","token_type":"Bearer","expires_at":"\(date)","user":{"id":"user-1","display_name":"","created_at":"\(date)","identities":[{"provider":"apple","email_verified":true}]}}
            """.utf8)
            let session = try AccountAPI.decoder().decode(AccountSession.self, from: data)
            XCTAssertEqual(session.accessToken, "secret")
            XCTAssertTrue(session.user.identities[0].emailVerified)
            XCTAssertNil(session.user.identities[0].email)
            let restored = try JSONDecoder().decode(AccountSession.self, from: JSONEncoder().encode(session))
            XCTAssertEqual(restored.expiresAt, session.expiresAt)
        }
    }
    func testAppleLoginContract() async throws {
        AccountMockProtocol.state.set { request in
            XCTAssertEqual(request.url?.path, "/v1/auth/apple")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let stream = request.httpBodyStream!
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let length = stream.read(&buffer, maxLength: buffer.count)
                if length <= 0 { break }; data.append(buffer, count: length)
            }
            let body = try JSONSerialization.jsonObject(with: data) as! [String: String]
            XCTAssertEqual(body, ["id_token": "signed-apple-token", "challenge_id": "challenge"])
            return (200, Data("""
            {"access_token":"session-token","token_type":"Bearer","expires_at":"2099-01-01T00:00:00Z","user":{"id":"u","display_name":"","created_at":"2026-10-22T14:00:00Z","identities":[]}}
            """.utf8))
        }
        let result = try await client().login(provider: "apple", idToken: "signed-apple-token", challengeID: "challenge")
        XCTAssertEqual(result.accessToken, "session-token")
    }
    func testUnauthorizedAndDisabledProvider() async throws {
        AccountMockProtocol.state.set { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer local-session")
            return (401, Data())
        }
        do { _ = try await client().currentUser(token: "local-session"); XCTFail("Unauthorized accepted") }
        catch AccountAPIError.unauthorized { }
        AccountMockProtocol.state.set { _ in (503, Data()) }
        do { _ = try await client().providers(); XCTFail("Disabled service accepted") }
        catch AccountAPIError.unavailable { }
    }

    func testEmailLoginContractAndError() async throws {
        AccountMockProtocol.state.set { request in
            XCTAssertEqual(request.url?.path, "/v1/auth/email/login")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (401, Data(#"{"error":{"code":"invalid_credentials"}}"#.utf8))
        }
        do { _ = try await client().loginEmail(email: "u@example.com", password: "password"); XCTFail("Wrong password accepted") }
        catch AccountAPIError.invalidEmailCredentials { }
        XCTAssertEqual(AccountAPI.serviceURL(from: " http://192.168.3.4:8090/account/ ")?.path, "/")
        XCTAssertNil(AccountAPI.serviceURL(from: "http://public.example.com"))
    }
    private func client() throws -> AccountAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountMockProtocol.self]
        return try AccountAPI(baseURL: URL(string: "https://account.example")!, session: URLSession(configuration: configuration))
    }
}

private final class AccountMockProtocol: URLProtocol, @unchecked Sendable {
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var handler: (@Sendable (URLRequest) throws -> (Int, Data))?
        func set(_ handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)) { lock.lock(); defer { lock.unlock() }; self.handler = handler }
        func respond(_ request: URLRequest) throws -> (Int, Data) {
            lock.lock(); let handler = handler; lock.unlock()
            return try handler!(request)
        }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.state.respond(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}
