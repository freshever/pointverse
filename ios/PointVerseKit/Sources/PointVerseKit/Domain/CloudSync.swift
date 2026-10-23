import CryptoKit
import Foundation

public struct CloudSnapshotAsset: Sendable {
    public let id: String
    public let relativePath: String
    public let sha256: String
    public let byteCount: Int64
    public let kind: String
}
public struct CloudPointSnapshot: Sendable {
    public let pointID: PointID
    public let title: String
    public let preview: String
    public let revision: Int
    public let assets: [CloudSnapshotAsset]
    public let manifest: Data
    public var hash: String { SHA256.hash(data: manifest).map { String(format: "%02x", $0) }.joined() }
}
public struct CloudPointVersion: Decodable, Identifiable, Sendable {
    public let pointId: String
    public let manifestHash: String
    public let revision: Int
    public let title: String
    public let preview: String
    public let createdAt: Double
    public let assetCount: Int
    public let uploadedAt: Date
    public let thumbnailHash: String?
    public let audioHash: String?
    public var id: String { pointId + ":" + manifestHash }
}
public enum CloudSyncError: Error, LocalizedError, Sendable {
    case quota, tooLarge, checksum, missingAssets, missingLocalAsset, invalidSnapshot
    public var errorDescription: String? {
        switch self {
        case .quota: "云端空间已满，暂时无法继续上传。"
        case .tooLarge: "附件或内容超出上传限制。单个附件最多 128 MB。"
        case .checksum: "文件校验失败，请重新上传。"
        case .missingAssets: "附件尚未全部上传，请重试。"
        case .missingLocalAsset: "本地附件缺失或尚未保存完成，暂时无法上传。"
        case .invalidSnapshot: "无法读取完整的想法内容，请稍后重试。"
        }
    }
}
