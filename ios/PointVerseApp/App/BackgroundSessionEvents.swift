import UIKit

@MainActor
final class BackgroundSessionEvents {
    static let shared = BackgroundSessionEvents()
    private var handlers: [String: () -> Void] = [:]

    func store(identifier: String, handler: @escaping () -> Void) {
        handlers[identifier] = handler
    }

    func finish(identifier: String) {
        handlers.removeValue(forKey: identifier)?()
    }
}

final class PointVerseAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            BackgroundSessionEvents.shared.store(identifier: identifier, handler: completionHandler)
        }
    }
}
