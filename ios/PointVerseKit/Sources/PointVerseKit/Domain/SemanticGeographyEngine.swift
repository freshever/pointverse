import Foundation

public enum SemanticGeographyEngine {
    public static func make(
        embeddings: [PointEmbeddingRecord],
        previous: [PointGeographyRecord],
        version: String = GeographyIdentity.relativeSemanticV6
    ) -> [PointGeographyRecord] {
        let records = embeddings.sorted { $0.pointID.rawValue.uuidString < $1.pointID.rawValue.uuidString }
        guard !records.isEmpty else { return [] }
        let revisionByID = Dictionary(uniqueKeysWithValues: records.map { ($0.pointID, $0.revision) })
        // A saved coordinate is reusable only while it describes the current
        // semantic content. Transcription, edits and image understanding all
        // bump the revision and must therefore be placed again.
        let reusable = previous.filter {
            $0.geographyVersion == version
                && ($0.isPinned || revisionByID[$0.pointID] == $0.contentRevision)
        }
        let previousByID = Dictionary(uniqueKeysWithValues: reusable.map { ($0.pointID, $0) })
        // Opening or refreshing the globe must be a snapshot read, not a full
        // layout pass. If every current embedding already has a valid address,
        // return it before decoding and comparing any vectors.
        if previousByID.count == records.count {
            return records.compactMap { previousByID[$0.pointID] }
        }
        let rawVectors = records.map { normalize($0.vector.map(Double.init)) }
        // Multilingual E5 vectors share a large common component, so their raw
        // cosine values are high even for unrelated sentences. Geography cares
        // about differences within this user's collection: remove the collection
        // centroid before comparing topics, while retaining the raw vector when
        // every item is effectively identical.
        let vectors = relativeVectors(rawVectors)
        // Similarity is immutable during spatial relaxation. Compute it once;
        // the old implementation repeated a 384-dimensional dot product for
        // every pair on every one of the 120 layout iterations.
        let similarities = similarityMatrix(vectors)
        let (seeds, communities) = communityAssignment(similarities)
        let centers = seeds.indices.map { fibonacciCenter(index: $0, count: seeds.count) }
        let active = Set(records.indices.filter { previousByID[records[$0].pointID] == nil })
        var positions = records.enumerated().map { index, record in
            if let stored = previousByID[record.pointID] { return cartesian(latitude: stored.latitude, longitude: stored.longitude) }
            let neighbors = records.indices.compactMap { candidate -> (Vector3, Double)? in
                guard candidate != index, let stored = previousByID[records[candidate].pointID] else { return nil }
                let score = similarities[index][candidate]
                guard score >= 0.88 else { return nil }
                return (cartesian(latitude: stored.latitude, longitude: stored.longitude), pow(score, 6))
            }
            if !neighbors.isEmpty {
                return neighbors.reduce(Vector3.zero) { $0 + $1.0 * $1.1 }.normalized
            }
            return deterministicPosition(id: record.pointID, center: centers[communities[index]])
        }
        let original = positions

        for iteration in 0..<120 where records.count > 1 {
            var forces = Array(repeating: Vector3.zero, count: records.count)
            for i in records.indices {
                for j in records.indices where j > i {
                    // Two persisted points cannot move, so their force has no
                    // effect on the result of an incremental placement.
                    guard active.contains(i) || active.contains(j) else { continue }
                    guard communities[i] == communities[j] else { continue }
                    let cosine = clamp(dot(positions[i], positions[j]), minimum: -1, maximum: 1)
                    let angle = max(0.025, acos(cosine))
                    let towardJ = tangent(from: positions[i], toward: positions[j])
                    let towardI = tangent(from: positions[j], toward: positions[i])
                    let repulsion = min(0.003, 0.00008 / (angle * angle + 0.002))
                    forces[i] = forces[i] - towardJ * repulsion
                    forces[j] = forces[j] - towardI * repulsion

                    let similarity = similarities[i][j]
                    guard similarity >= 0.88 else { continue }
                    let strength = clamp((similarity - 0.88) / 0.12, minimum: 0, maximum: 1)
                    let targetAngle = 0.14 - strength * 0.105
                    let attraction = (angle - targetAngle) * (0.016 + strength * 0.032)
                    forces[i] = forces[i] + towardJ * attraction
                    forces[j] = forces[j] + towardI * attraction
                }
            }

            let cooling = 0.3 + 0.7 * Double(120 - iteration) / 120
            for index in positions.indices {
                let candidate = (positions[index] + forces[index] * cooling).normalized
                if previousByID[records[index].pointID] != nil {
                    // Persisted geography is a spatial-memory contract. Existing
                    // points remain fixed; a future explicit migration may apply
                    // a bounded drift budget under a new geography version.
                    positions[index] = original[index]
                } else {
                    positions[index] = confinedToRegion(candidate, center: centers[communities[index]])
                }
            }
        }

        return records.indices.map { index in
            let coordinate = spherical(positions[index])
            let nearestScore = similarities[index].enumerated()
                .filter { $0.offset != index }
                .map(\.element)
                .max() ?? 0
            return PointGeographyRecord(
                pointID: records[index].pointID,
                geographyVersion: version,
                contentRevision: records[index].revision,
                communityID: previousByID[records[index].pointID]?.communityID
                    ?? records[seeds[communities[index]]].pointID.rawValue.uuidString,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                placementConfidence: clamp((nearestScore + 1) / 2, minimum: 0, maximum: 1),
                isPinned: previousByID[records[index].pointID]?.isPinned ?? false
            )
        }
    }

    private struct Vector3 {
        var x: Double
        var y: Double
        var z: Double
        static let zero = Vector3(x: 0, y: 0, z: 0)
        static func + (lhs: Self, rhs: Self) -> Self { .init(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z) }
        static func - (lhs: Self, rhs: Self) -> Self { .init(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z) }
        static func * (lhs: Self, rhs: Double) -> Self { .init(x: lhs.x * rhs, y: lhs.y * rhs, z: lhs.z * rhs) }
        var length: Double { sqrt(x * x + y * y + z * z) }
        var normalized: Self { length > 0.000_001 ? self * (1 / length) : .init(x: 0, y: 0, z: 1) }
    }

    private static func normalize(_ vector: [Double]) -> [Double] {
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? vector.map { $0 / norm } : vector
    }

    private static func relativeVectors(_ vectors: [[Double]]) -> [[Double]] {
        guard vectors.count > 1, let dimension = vectors.first?.count, dimension > 0,
              vectors.allSatisfy({ $0.count == dimension }) else { return vectors }
        var centroid = Array(repeating: 0.0, count: dimension)
        for vector in vectors {
            for index in 0..<dimension { centroid[index] += vector[index] }
        }
        centroid = centroid.map { $0 / Double(vectors.count) }
        return vectors.map { vector in
            let residual = zip(vector, centroid).map { $0.0 - $0.1 }
            let norm = sqrt(residual.reduce(0) { $0 + $1 * $1 })
            return norm > 0.000_1 ? residual.map { $0 / norm } : vector
        }
    }

    private static func dot(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count else { return -1 }
        return zip(lhs, rhs).reduce(0) { $0 + $1.0 * $1.1 }
    }

    private static func similarityMatrix(_ vectors: [[Double]]) -> [[Double]] {
        var result = Array(repeating: Array(repeating: 0.0, count: vectors.count), count: vectors.count)
        for index in vectors.indices { result[index][index] = 1 }
        for i in vectors.indices {
            for j in vectors.indices where j > i {
                let score = dot(vectors[i], vectors[j])
                result[i][j] = score
                result[j][i] = score
            }
        }
        return result
    }

    private static func dot(_ lhs: Vector3, _ rhs: Vector3) -> Double {
        lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z
    }

    private static func tangent(from origin: Vector3, toward target: Vector3) -> Vector3 {
        (target - origin * dot(origin, target)).normalized
    }

    private static func communityAssignment(_ similarities: [[Double]]) -> ([Int], [Int]) {
        let maxCommunities = min(12, max(1, Int(ceil(sqrt(Double(similarities.count)) * 1.7))))
        var seeds = [0]
        while seeds.count < maxCommunities {
            let candidate = similarities.indices.filter { !seeds.contains($0) }.max { lhs, rhs in
                let leftDistance = 1 - seeds.map { similarities[lhs][$0] }.max()!
                let rightDistance = 1 - seeds.map { similarities[rhs][$0] }.max()!
                return leftDistance == rightDistance ? lhs > rhs : leftDistance < rightDistance
            }
            guard let candidate,
                  1 - seeds.map({ similarities[candidate][$0] }).max()! >= 0.07 else { break }
            seeds.append(candidate)
        }
        let assignment = similarities.indices.map { index in
            seeds.indices.max { lhs, rhs in
                similarities[index][seeds[lhs]] < similarities[index][seeds[rhs]]
            }!
        }
        return (seeds, assignment)
    }

    private static func fibonacciCenter(index: Int, count: Int) -> Vector3 {
        let y = 1 - 2 * (Double(index) + 0.5) / Double(count)
        let longitude = Double(index) * .pi * (3 - sqrt(5))
        let radius = sqrt(max(0, 1 - y * y))
        return Vector3(x: radius * cos(longitude), y: y, z: radius * sin(longitude))
    }

    private static func deterministicPosition(id: PointID, center: Vector3) -> Vector3 {
        let bytes = withUnsafeBytes(of: id.rawValue.uuid) { Array($0) }
        let a = Double((Int(bytes[0]) << 8) | Int(bytes[1])) / 65_535
        let b = Double((Int(bytes[2]) << 8) | Int(bytes[3])) / 65_535
        let radius = sqrt(a) * 0.13
        let bearing = b * 2 * Double.pi
        let east = Vector3(x: -center.z, y: 0, z: center.x).normalized
        let north = Vector3(x: center.y * east.z, y: center.z * east.x - center.x * east.z, z: -center.y * east.x).normalized
        return (center * cos(radius) + east * (sin(radius) * cos(bearing)) + north * (sin(radius) * sin(bearing))).normalized
    }

    private static func confinedToRegion(_ point: Vector3, center: Vector3) -> Vector3 {
        let angle = acos(clamp(dot(point, center), minimum: -1, maximum: 1))
        let maximumAngle = 0.22
        guard angle > maximumAngle else { return point }
        let radial = (point - center * dot(point, center)).normalized
        return (center * cos(maximumAngle) + radial * sin(maximumAngle)).normalized
    }

    private static func cartesian(latitude: Double, longitude: Double) -> Vector3 {
        let lat = latitude * .pi / 180
        let lon = longitude * .pi / 180
        return .init(x: cos(lat) * cos(lon), y: sin(lat), z: cos(lat) * sin(lon))
    }

    private static func spherical(_ point: Vector3) -> (latitude: Double, longitude: Double) {
        let unit = point.normalized
        return (asin(clamp(unit.y, minimum: -1, maximum: 1)) * 180 / .pi, atan2(unit.z, unit.x) * 180 / .pi)
    }

    private static func clamp(_ value: Double, minimum: Double, maximum: Double) -> Double {
        min(maximum, max(minimum, value))
    }
}
