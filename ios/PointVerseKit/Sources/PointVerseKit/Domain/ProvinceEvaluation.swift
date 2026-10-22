import Foundation

/// Immutable evidence: evaluations remain interpretable after content or clustering changes.
public struct ProvinceEvaluation: Codable, Identifiable, Sendable {
    public struct Member: Codable, Sendable {
        public let id: PointID
        public let revision: Int?
        public let text: String
        public init(id: PointID, revision: Int?, text: String) {
            self.id = id; self.revision = revision; self.text = text
        }
    }
    public let id: UUID
    public let createdAt: Date
    public let provinceID: String
    public let provinceName: String
    public let members: [Member]
    public var verdict: String
    public var humanScore: Int?
    public var annotations: [String: String]
    public var pairAnnotations: [String: String]
    public var note: String
    public var aiReports: [String]
    public var aiModels: [String]
    public var decision: String
    public var metrics: ProvinceQualityMetrics?
    public let version: String
    public let geographyVersion: String
    public let scopeLevel: String?
    public let hierarchyPath: [String]?

    public init(provinceID: String, provinceName: String, members: [Member], scopeLevel: String? = nil, hierarchyPath: [String]? = nil) {
        id = UUID(); createdAt = Date(); self.provinceID = provinceID
        self.provinceName = provinceName; self.members = members
        verdict = "暂时无法判断"; humanScore = nil; annotations = [:]; pairAnnotations = [:]
        note = ""; aiReports = []; aiModels = []
        decision = "尚未处理"; version = "province-review-v1"
        geographyVersion = GeographyIdentity.relativeSemanticV6
        self.scopeLevel = scopeLevel; self.hierarchyPath = hierarchyPath
    }
}

public struct ProvinceQualityMetrics: Codable, Sendable {
    public struct Pair: Codable, Sendable, Identifiable {
        public let a: PointID
        public let b: PointID
        public let similarity: Double
        public var id: String { a.rawValue.uuidString + ":" + b.rawValue.uuidString }
    }
    public let validMembers: Int
    public let sampledMembers: Int
    public let sampledOutsiders: Int
    public let pairCount: Int
    public let median: Double?
    public let lowerDecile: Double?
    public let upperDecile: Double?
    public let outsideMedian: Double?
    public let suspiciousIDs: [PointID]
    public let weakestPairs: [Pair]
    public let modelID: String

    /// Deterministic bounded samples, independent of camera and input order. Raw cosine is not probability.
    public static func compute(memberIDs: Set<PointID>, embeddings: [PointEmbeddingRecord],
                               modelID: String) -> Self {
        let candidates = embeddings.filter { $0.modelID == modelID && !$0.vector.isEmpty
            && $0.vector.allSatisfy(\.isFinite) }.sorted { $0.pointID.rawValue.uuidString < $1.pointID.rawValue.uuidString }
        // A malformed vector must not determine the dimensions accepted for the whole dataset.
        let dimensions = Dictionary(grouping: candidates, by: { $0.vector.count })
        let dimension = dimensions.keys.sorted {
            let left = dimensions[$0]!.count, right = dimensions[$1]!.count
            return left == right ? $0 < $1 : left > right
        }.first ?? 0
        func normalized(_ record: PointEmbeddingRecord) -> (PointID, [Double])? {
            guard record.vector.count == dimension else { return nil }
            let values = record.vector.map(Double.init)
            let norm = sqrt(values.reduce(0) { $0 + $1 * $1 })
            guard norm.isFinite, norm > 0.000001 else { return nil }
            return (record.pointID, values.map { $0 / norm })
        }
        let vectors = candidates.compactMap(normalized).sorted { $0.0.rawValue.uuidString < $1.0.rawValue.uuidString }
        let inside = vectors.filter { memberIDs.contains($0.0) }
        func sample(_ values: [(PointID, [Double])], limit: Int) -> [(PointID, [Double])] {
            guard values.count > limit else { return values }
            return (0..<limit).map { values[$0 * (values.count - 1) / (limit - 1)] }
        }
        let a = sample(inside, limit: 128)
        let b = sample(vectors.filter { !memberIDs.contains($0.0) }, limit: 128)
        func cosine(_ x: [Double], _ y: [Double]) -> Double {
            min(1, max(-1, zip(x, y).reduce(0) { $0 + $1.0 * $1.1 }))
        }
        var pairs: [Double] = [], outside: [Double] = [], suspicious: [PointID] = []
        var reviewedPairs: [Pair] = []
        for i in a.indices {
            for j in a.indices where j > i {
                let score = cosine(a[i].1, a[j].1)
                pairs.append(score)
                reviewedPairs.append(.init(a: a[i].0, b: a[j].0, similarity: score))
            }
            let within = a.indices.filter { $0 != i }.map { cosine(a[i].1, a[$0].1) }
            let cross = b.map { cosine(a[i].1, $0.1) }
            outside.append(contentsOf: cross)
            if let own = quantile(within, 0.5), let other = cross.max(), other > own + 0.05 {
                suspicious.append(a[i].0)
            }
        }
        return Self(validMembers: inside.count, sampledMembers: a.count, sampledOutsiders: b.count,
                    pairCount: pairs.count, median: quantile(pairs, 0.5), lowerDecile: quantile(pairs, 0.1),
                    upperDecile: quantile(pairs, 0.9), outsideMedian: quantile(outside, 0.5),
                    suspiciousIDs: suspicious,
                    weakestPairs: Array(reviewedPairs.sorted { $0.similarity == $1.similarity ? $0.id < $1.id : $0.similarity < $1.similarity }.prefix(12)),
                    modelID: modelID)
    }

    private static func quantile(_ values: [Double], _ fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted(), position = Double(values.count - 1) * fraction
        let low = Int(position), high = min(sorted.count - 1, Int(ceil(position)))
        return sorted[low] + (sorted[high] - sorted[low]) * (position - Double(low))
    }
}
