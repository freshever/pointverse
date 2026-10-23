import CryptoKit
import Foundation
import XCTest
@testable import PointVerseKit

final class CloudSyncLiveTests: XCTestCase {
    func testEmailLoginUploadAndReadBack() async throws {
        guard let address = ProcessInfo.processInfo.environment["POINTVERSE_SYNC_TEST_URL"], let url = URL(string: address),
              let fixtureRoot = ProcessInfo.processInfo.environment["POINTVERSE_SYNC_FIXTURES"] else { throw XCTSkip("Local Docker sync integration is opt-in") }
        let client = try AccountAPI(baseURL: url, allowLocalHTTP: true)
        let email = "ios-sync-" + UUID().uuidString.lowercased() + "@example.invalid"
        let password = "Sync-preview-passphrase-2026"
        var registration = URLRequest(url: url.appendingPathComponent("v1/auth/email/register"))
        registration.httpMethod = "POST"
        registration.setValue("application/json", forHTTPHeaderField: "Content-Type")
        registration.httpBody = try JSONEncoder().encode(["email": email, "password": password, "password_confirmation": password])
        let (data, response) = try await URLSession.shared.data(for: registration)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 201)
        let initial = try AccountAPI.decoder().decode(AccountSession.self, from: data)
        let session = try await client.loginEmail(email: email, password: password)
        XCTAssertEqual(session.user.id, initial.user.id)
        try await client.logout(token: initial.accessToken)
        let db = try PointDatabase(inMemory: true); try await db.migrate()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = try await db.commitTextPoint(text: "把一闪而过的想法留下来，让思考慢慢长成自己的宇宙。")
        try await db.saveCandidateTitle(pointID: text, title: "从一个点，开始连接", modelID: "test", modelSHA256: "test")
        let imagePoint = try await db.commitTextPoint(text: "一张关于色彩和远方的随手记录。原图与文字一起保留。")
        try await db.saveCandidateTitle(pointID: imagePoint, title: "光线与远方", modelID: "test", modelSHA256: "test")
        let imageData = try Data(contentsOf: URL(fileURLWithPath: fixtureRoot).appendingPathComponent("image.png"))
        let imageID = UUID(); let imagePath = "blobs/images/\(imageID.uuidString).png"
        try FileManager.default.createDirectory(at: root.appendingPathComponent("blobs/images"), withIntermediateDirectories: true)
        try imageData.write(to: root.appendingPathComponent(imagePath))
        try await db.addImage(pointID: imagePoint, id: imageID, relativePath: imagePath, sha256: digest(imageData), byteCount: Int64(imageData.count), recognizedText: "色彩试验")
        let audioData = try Data(contentsOf: URL(fileURLWithPath: fixtureRoot).appendingPathComponent("audio.wav"))
        let audioID = UUID(); let audioPath = "blobs/audio/\(audioID.uuidString).wav"
        try FileManager.default.createDirectory(at: root.appendingPathComponent("blobs/audio"), withIntermediateDirectories: true)
        try audioData.write(to: root.appendingPathComponent(audioPath))
        let audio = StoredAudio(assetID: audioID, relativePath: audioPath, sha256: digest(audioData), byteCount: Int64(audioData.count), durationMilliseconds: 1000, codec: "pcm_s16le", sampleRate: 22050)
        let voice = try await db.commitVoiceCapture(.init(operationID: UUID(), audio: audio))
        try await db.saveTranscript(pointID: voice, engineText: "把声音也保留下来，往后可以回到这一刻。", modelID: "test-speech", modelSHA256: "test")
        try await db.saveCandidateTitle(pointID: voice, title: "留住原来的声音", modelID: "test", modelSHA256: "test")
        for point in [text,imagePoint,voice] {
            let snapshot = try await db.cloudSnapshot(id: point)
            for asset in snapshot.assets {
                try await client.uploadCloudAsset(url: root.appendingPathComponent(asset.relativePath), asset: asset, token: session.accessToken) { _,_ in }
                // HEAD-based retry must reuse an already committed blob.
                try await client.uploadCloudAsset(url: root.appendingPathComponent(asset.relativePath), asset: asset, token: session.accessToken) { _,_ in }
            }
            let version = try await client.commitCloudPoint(snapshot, token: session.accessToken)
            let repeated = try await client.commitCloudPoint(snapshot, token: session.accessToken)
            XCTAssertEqual(version.id, repeated.id)
        }
        let versions = try await client.cloudVersions(token: session.accessToken)
        XCTAssertEqual(versions.count, 3)
        XCTAssertTrue(versions.contains { $0.thumbnailHash != nil })
        XCTAssertTrue(versions.contains { $0.audioHash != nil })
        for (hash, original) in [(digest(imageData), imageData), (digest(audioData), audioData)] {
            var request = URLRequest(url: url.appendingPathComponent("v1/sync/assets/" + hash))
            request.setValue("Bearer " + session.accessToken, forHTTPHeaderField: "Authorization")
            let (restored, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(restored, original)
        }
        try await client.logout(token: session.accessToken)
        do { _ = try await client.currentUser(token: session.accessToken); XCTFail("Logout failed") }
        catch AccountAPIError.unauthorized { }
        print("CLOUD_SMOKE_EMAIL=\(email)")
        print("CLOUD_SMOKE_USER=\(session.user.id)")
    }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x",$0) }.joined() }
}
