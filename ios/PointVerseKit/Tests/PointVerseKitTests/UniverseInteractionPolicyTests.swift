import Foundation
import Testing
@testable import PointVerseKit

@Test func cameraFlightUsesProgressiveRelativeMagnification() {
    #expect(abs(UniverseInteractionPolicy.flightZoom(from: 1, to: 10000, progress: 0.5) - 100) < 0.001)
    #expect(UniverseInteractionPolicy.flightZoom(from: 2, to: 200, progress: 0) == 2)
    #expect(abs(UniverseInteractionPolicy.flightZoom(from: 200, to: 2, progress: 1) - 2) < 0.001)
    let values = (0...100).map { UniverseInteractionPolicy.flightZoom(from: 1, to: 10000, progress: Double($0) / 100) }
    for index in 1..<values.count { #expect(values[index] > values[index - 1]) }
}

@Test func distantSystemsHidePlanetsAndUnfoldSmoothly() {
    #expect(UniverseInteractionPolicy.systemDetailOpacity(projectedDiameter: 100) == 0)
    #expect(UniverseInteractionPolicy.systemDetailOpacity(projectedDiameter: 240) == 0)
    #expect(UniverseInteractionPolicy.systemDetailOpacity(projectedDiameter: 300) == 0.5)
    #expect(UniverseInteractionPolicy.systemDetailOpacity(projectedDiameter: 360) == 1)
    #expect(UniverseInteractionPolicy.systemDetailOpacity(projectedDiameter: 1000) == 1)
    #expect(UniverseInteractionPolicy.systemDetailOpacity(projectedDiameter: .nan) == 0)
}

@Test func richerPlanetsAreLargerAndOccupyInnerOrbits() {
    let counts = [1, 10, 100, 1000, 10000]
    let radii = counts.map { UniverseInteractionPolicy.planetRadius(pointCount: $0) }
    for index in 1..<radii.count { #expect(radii[index] > radii[index - 1]) }
    #expect(radii.allSatisfy { $0 >= 0.48 && $0 <= 1.18 })
    #expect(UniverseInteractionPolicy.planetRadius(pointCount: -1) == 0.48)
    let planets = [(id: 8, count: 5), (id: 4, count: 100), (id: 2, count: 5)]
    #expect(UniverseInteractionPolicy.orderedPlanetIDs(planets) == [4, 2, 8])
    #expect(UniverseInteractionPolicy.orderedPlanetIDs(planets.reversed()) == [4, 2, 8])
}

@Test func clickedPlanetFitsRoughlyHalfScreenWithoutOverflow() {
    #expect(abs(UniverseInteractionPolicy.clickedPlanetDiameter(width: 390, height: 650) - 343.2) < 0.001)
    let landscape = UniverseInteractionPolicy.clickedPlanetDiameter(width: 1000, height: 600)
    #expect(abs(landscape - 336) < 0.001)
    #expect(UniverseInteractionPolicy.clickedPlanetDiameter(width: 0, height: 600) == 0)
    #expect(UniverseInteractionPolicy.clickedPlanetDiameter(width: .infinity, height: 600) == 0)
}

@Test func orbitPauseResumesSmoothlyWithoutCatchingUpMissedTime() {
    #expect(UniverseInteractionPolicy.idlePause == 6)
    #expect(UniverseInteractionPolicy.orbitDelta(previous: 10, now: 10.05, resumeAt: 16) == 0)
    #expect(UniverseInteractionPolicy.orbitDelta(previous: 15.98, now: 16.02, resumeAt: 16) > 0)
    #expect(UniverseInteractionPolicy.orbitDelta(previous: 15.98, now: 16.02, resumeAt: 16) < 0.021)
    #expect(UniverseInteractionPolicy.orbitDelta(previous: 10, now: 200, resumeAt: 16) <= 0.1)
    #expect(UniverseInteractionPolicy.orbitDelta(previous: 10, now: 9, resumeAt: 0) == 0)
    #expect(UniverseInteractionPolicy.orbitDelta(previous: .nan, now: 10, resumeAt: 0) == 0)
    #expect(UniverseInteractionPolicy.orbitRate(index: 0) > UniverseInteractionPolicy.orbitRate(index: 1))
    #expect(UniverseInteractionPolicy.orbitRate(index: 5) > 0)
}
