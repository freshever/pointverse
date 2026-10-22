import Foundation

/// Conservative local subtopics. Missing evidence, homogeneous content or tiny
/// groups stay at their parent instead of inventing geographic subdivisions.
public enum SemanticSubtopicEngine {
    public static func communityUnits(memberIDs: [PointID], geographies: [PointGeographyRecord]) -> [[PointID]] {
        let lookup = Dictionary(geographies.map { ($0.pointID, $0.communityID) }, uniquingKeysWith: { first, _ in first })
        let groups = Dictionary(grouping: Set(memberIDs)) { id in
            lookup[id].flatMap { $0 } ?? "pending:\(id.rawValue.uuidString)"
        }
        return groups.keys.sorted().map { key in groups[key]!.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString } }
    }

    public static func partition(memberIDs: [PointID], embeddings: [PointEmbeddingRecord], maximumGroups: Int = 6) -> [[PointID]] {
        let ids = Array(Set(memberIDs)).sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
        guard ids.count >= 4, maximumGroups > 1 else { return ids.isEmpty ? [] : [ids] }
        let lookup = Dictionary(embeddings.map { ($0.pointID, $0.vector) }, uniquingKeysWith: { first, _ in first })
        guard let dimension = ids.first.flatMap({ lookup[$0]?.count }), dimension > 0 else { return [ids] }
        var vectors: [[Double]] = []
        for id in ids {
            guard let raw = lookup[id], raw.count == dimension, raw.allSatisfy(\.isFinite) else { return [ids] }
            let vector = raw.map(Double.init), norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
            guard norm > 0.000001 else { return [ids] }
            vectors.append(vector.map { $0 / norm })
        }
        func dot(_ a: [Double], _ b: [Double]) -> Double { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
        func center(_ indices: [Int]) -> [Double] {
            var result = Array(repeating: 0.0, count: dimension)
            for i in indices { for d in 0..<dimension { result[d] += vectors[i][d] } }
            let norm = sqrt(dot(result, result))
            return norm > 0.000001 ? result.map { $0 / norm } : vectors[indices[0]]
        }
        // Identical/near-identical notes must never split due to UUID order.
        let rawCenter = center(Array(ids.indices))
        let dispersion = vectors.map { 1 - dot($0, rawCenter) }.reduce(0, +) / Double(ids.count)
        guard dispersion > 0.008 else { return [ids] }
        var mean = Array(repeating: 0.0, count: dimension)
        for vector in vectors { for d in 0..<dimension { mean[d] += vector[d] / Double(ids.count) } }
        vectors = vectors.map { vector in
            let residual = zip(vector, mean).map(-)
            let norm = sqrt(dot(residual, residual))
            return norm > 0.000001 ? residual.map { $0 / norm } : vector
        }
        let cap = min(maximumGroups, ids.count / 2)
        var seeds = [0]
        while seeds.count < cap {
            let candidates = ids.indices.filter { !seeds.contains($0) }
            guard let next = candidates.min(by: { a, b in
                let left = seeds.map { dot(vectors[a], vectors[$0]) }.max()!
                let right = seeds.map { dot(vectors[b], vectors[$0]) }.max()!
                return left == right ? a < b : left < right
            }), seeds.map({ dot(vectors[next], vectors[$0]) }).max()! < 0.55 else { break }
            seeds.append(next)
        }
        guard seeds.count > 1 else { return [ids] }
        var centers = seeds.map { vectors[$0] }, assignment = Array(repeating: 0, count: ids.count)
        for _ in 0..<8 {
            for i in ids.indices {
                assignment[i] = centers.indices.max { dot(vectors[i], centers[$0]) < dot(vectors[i], centers[$1]) }!
            }
            for k in centers.indices {
                let group = ids.indices.filter { assignment[$0] == k }
                if !group.isEmpty { centers[k] = center(group) }
            }
        }
        var groups = centers.indices.map { k in ids.indices.filter { assignment[$0] == k } }.filter { !$0.isEmpty }
        let substantial = groups.filter { $0.count >= 2 }
        guard substantial.count > 1 else { return [ids] }
        let small = groups.filter { $0.count < 2 }.flatMap { $0 }
        groups = substantial
        for index in small {
            let target = groups.indices.max { dot(vectors[index], center(groups[$0])) < dot(vectors[index], center(groups[$1])) }!
            groups[target].append(index)
        }
        // Require a measurable separation; a split is optional, not a quota.
        let groupCenters = groups.map(center)
        let within = groups.enumerated().flatMap { k, group in group.map { dot(vectors[$0], groupCenters[k]) } }.reduce(0, +) / Double(ids.count)
        let between = groupCenters.indices.flatMap { a in groupCenters.indices.filter { $0 > a }.map { dot(groupCenters[a], groupCenters[$0]) } }
        guard let closest = between.max(), within - closest >= 0.15 else { return [ids] }
        return groups.map { $0.map { ids[$0] }.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString } }
            .sorted { $0[0].rawValue.uuidString < $1[0].rawValue.uuidString }
    }
}
