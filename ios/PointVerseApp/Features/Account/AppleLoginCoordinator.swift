import AuthenticationServices
import PointVerseKit
import UIKit

@MainActor
final class AppleLoginCoordinator: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<String, Error>?
    private var window: UIWindow?
    private var controller: ASAuthorizationController?

    func signIn(nonce: String, window: UIWindow) async throws -> String {
        self.window = window
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let request = ASAuthorizationAppleIDProvider().createRequest()
            request.requestedScopes = [.email]
            request.nonce = nonce
            let controller = ASAuthorizationController(authorizationRequests: [request])
            self.controller = controller
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor { window! }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let data = credential.identityToken, let token = String(data: data, encoding: .utf8) else {
            finish(.failure(AccountAPIError.invalidCredential)); return
        }
        finish(.success(token))
    }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) { finish(.failure(error)) }
    private func finish(_ result: Result<String, Error>) {
        let pending = continuation
        continuation = nil; controller = nil; window = nil
        pending?.resume(with: result)
    }
}
