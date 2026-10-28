import Foundation

public struct CloudImageJob: Decodable, Sendable {
    public struct ImageData: Decodable, Sendable { public let b64Json: String }
    public let id: String
    public let status: String
    public let model: String?
    public let data: [ImageData]?
    public let error: String?
}

extension AccountAPI {
    public func createImage(prompt: String, requestID: UUID, token: String) async throws -> CloudImageJob {
        struct Input: Encodable { let prompt: String; let request_id: String; let model = "pointverse-image"; let size = "512x512"; let n = 1 }
        let body = try JSONEncoder().encode(Input(prompt: prompt, request_id: requestID.uuidString.lowercased()))
        let data = try await request("v1/ai/images/generations", method: "POST", body: body, token: token)
        return try Self.decoder().decode(CloudImageJob.self, from: data)
    }
    public func imageJob(id: String, token: String) async throws -> CloudImageJob {
        guard UUID(uuidString: id) != nil else { throw AccountAPIError.invalidResponse }
        return try Self.decoder().decode(CloudImageJob.self, from: await request("v1/ai/jobs/" + id, method: "GET", token: token))
    }
    public func cancelImageJob(id: String, token: String) async throws {
        guard UUID(uuidString: id) != nil else { throw AccountAPIError.invalidResponse }
        _ = try await request("v1/ai/jobs/" + id + "/cancel", method: "POST", body: Data("{}".utf8), token: token)
    }
}
