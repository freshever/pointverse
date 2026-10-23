import CryptoKit
import Foundation
import XCTest
@testable import PointVerseKit

final class CloudSnapshotTests: XCTestCase {
    func testStableSnapshotTracksChangesAndOriginals() async throws {
        let db = try PointDatabase(inMemory: true)
        try await db.migrate()
        let point = try await db.commitTextPoint(text: "这是一条需要上传的原文。")
        let first = try await db.cloudSnapshot(id: point)
        let repeated = try await db.cloudSnapshot(id: point)
        XCTAssertEqual(first.hash, repeated.hash)
        try await db.appendConversationMessage(pointID: point, role: "assistant", text: "继续思考的结果", modelID: "test-model")
        let updated = try await db.cloudSnapshot(id: point)
        XCTAssertNotEqual(first.hash, updated.hash)
        XCTAssertGreaterThan(updated.revision, first.revision)
        let object = try JSONSerialization.jsonObject(with: updated.manifest) as! [String: Any]
        let payload = object["payload"] as! [String: Any]
        XCTAssertEqual((payload["messages"] as! [[String: Any]]).count, 2)
        XCTAssertNil(payload["embeddings"])
        let data = Data([1,2,3])
        let hash = SHA256.hash(data: data).map { String(format: "%02x",$0) }.joined()
        try await db.addImage(pointID: point, id: UUID(), relativePath: "blobs/images/test.jpg", sha256: hash, byteCount: Int64(data.count), recognizedText: "照片文字")
        let image = try await db.cloudSnapshot(id: point)
        XCTAssertEqual(image.assets.count, 1)
        XCTAssertEqual(image.assets[0].kind, "image")
        XCTAssertEqual(image.assets[0].sha256, hash)
        _ = try await db.moveToTrash([.init(pointID: point, reason: "test")])
        do { _ = try await db.cloudSnapshot(id: point); XCTFail("Trashed point is uploadable") }
        catch CloudSyncError.invalidSnapshot { }
    }
}
