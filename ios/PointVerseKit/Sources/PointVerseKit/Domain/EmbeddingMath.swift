import Foundation

public enum EmbeddingMath {
    public static func normalize(_ vector: [Float]) -> [Float] {
        let magnitude = sqrt(vector.reduce(Float.zero) { $0 + $1 * $1 })
        guard magnitude > 0 else { return vector }
        return vector.map { $0 / magnitude }
    }

    public static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Float? {
        guard !lhs.isEmpty, lhs.count == rhs.count else { return nil }
        var dot: Float = 0
        var left: Float = 0
        var right: Float = 0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            left += lhs[index] * lhs[index]
            right += rhs[index] * rhs[index]
        }
        guard left > 0, right > 0 else { return nil }
        return dot / sqrt(left * right)
    }

    public static func encodeFloat16(_ vector: [Float]) -> Data {
        var data = Data(capacity: vector.count * MemoryLayout<UInt16>.size)
        for value in vector {
            var bits = Float16(value).bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    public static func decodeFloat16(_ data: Data, dimension: Int) -> [Float]? {
        guard dimension >= 0, data.count == dimension * MemoryLayout<UInt16>.size else { return nil }
        return data.withUnsafeBytes { bytes in
            (0..<dimension).map { index in
                let offset = index * 2
                let bits = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
                return Float(Float16(bitPattern: bits))
            }
        }
    }

    public static func topK(
        query: [Float],
        records: [PointEmbeddingRecord],
        excluding pointID: PointID? = nil,
        limit: Int
    ) -> [SimilarityHit] {
        guard limit > 0 else { return [] }
        return records.compactMap { record -> SimilarityHit? in
            guard record.pointID != pointID, let score = cosine(query, record.vector) else { return nil }
            return SimilarityHit(pointID: record.pointID, score: score)
        }
        .sorted { $0.score > $1.score }
        .prefix(limit)
        .map { $0 }
    }
}
