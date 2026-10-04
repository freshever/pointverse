import Foundation
import WatchConnectivity

final class WatchTransferManager: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchTransferManager()
    private let session = WCSession.default
    private let lock = NSLock()
    private var pending: [(URL, Data)] = []
    var onAcknowledged: (@Sendable (UUID) -> Void)?

    func activate() {
        guard WCSession.isSupported() else { return }
        session.delegate = self
        session.activate()
    }

    func enqueue(fileURL: URL, manifest: WatchCaptureManifest) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(manifest) else { return }
        lock.lock()
        pending.append((fileURL, data))
        lock.unlock()
        flushIfActivated()
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        flushIfActivated()
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let value = userInfo["acknowledgedCaptureID"] as? String,
              let captureID = UUID(uuidString: value) else { return }
        onAcknowledged?(captureID)
    }

    private func flushIfActivated() {
        guard session.activationState == .activated else { return }
        lock.lock()
        let transfers = pending
        pending.removeAll()
        lock.unlock()
        for (url, data) in transfers {
            session.transferFile(url, metadata: ["manifest": data])
        }
    }
}
