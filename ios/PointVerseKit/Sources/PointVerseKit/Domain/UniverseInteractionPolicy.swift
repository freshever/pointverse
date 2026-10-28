import Foundation

public enum UniverseInteractionPolicy {
    /// Target-relative dolly inversion, independent of unrelated foreground bodies.
    public static func dollyZoom(entryZoom: Double, entryGap: Double, targetGap: Double) -> Double {
        entryZoom * pow(max(0.000001, entryGap) / max(0.000001, targetGap), 1 / 0.72)
    }
    /// A shortcut can select a body in front of the previous camera. Rebase
    /// its dolly curve outside the body instead of collapsing depth to epsilon.
    public static func navigationEntryGap(cameraDistance: Double, planetDepth: Double, fittedGap: Double) -> Double {
        max(0.000001, max(cameraDistance - planetDepth, fittedGap))
    }
    /// Constant relative magnification, eased at takeoff and arrival.
    public static func flightZoom(from: Double, to: Double, progress: Double) -> Double {
        guard from > 0, to > 0, from.isFinite, to.isFinite else { return from }
        let t = min(1, max(0, progress))
        let eased = t * t * (3 - 2 * t)
        return exp(log(from) + (log(to) - log(from)) * eased)
    }
    public static func systemDetailOpacity(projectedDiameter: Double) -> Double {
        guard projectedDiameter.isFinite else { return 0 }
        let t = min(1, max(0, (projectedDiameter - 240) / 120))
        return t * t * (3 - 2 * t)
    }
    /// Bounded, strictly increasing size: even a small collection stays selectable.
    public static func planetRadius(pointCount: Int) -> Double {
        0.48 + 0.70 * (1 - exp(-sqrt(Double(max(0, pointCount))) / 10))
    }
    /// Larger collections occupy inner orbits; ties retain a stable identity order.
    public static func orderedPlanetIDs(_ counts: [(id: Int, count: Int)]) -> [Int] {
        counts.sorted { $0.count == $1.count ? $0.id < $1.id : $0.count > $1.count }.map(\.id)
    }
    public static let idlePause: Double = 6
    public static func clickedPlanetDiameter(width: Double, height: Double) -> Double {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return 0 }
        return min(width * 0.88, height * 0.56)
    }
    /// Integrate only active, unpaused time; never jump after backgrounding.
    public static func orbitDelta(previous: Double, now: Double, resumeAt: Double) -> Double {
        guard previous.isFinite, now.isFinite, resumeAt.isFinite else { return 0 }
        return min(0.1, max(0, now - max(previous, resumeAt)))
    }
    public static func orbitRate(index: Int) -> Double {
        2 * .pi / (180 + Double(max(0, index)) * 70)
    }
}
