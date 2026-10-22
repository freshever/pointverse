import Testing
@testable import PointVerseKit

@Test func mindMapOnlyTraversesExpandedBranches() {
    let root = MindMapBranch(id: "root", children: [.init(id: "system", children: [.init(id: "planet")])])
    let closed = ReadOnlyMindMapLayout.make(root: root, expanded: [])
    #expect(closed.map(\.id) == ["root"])
    let first = ReadOnlyMindMapLayout.make(root: root, expanded: ["root"])
    #expect(first.map(\.id) == ["root", "system"])
    let open = ReadOnlyMindMapLayout.make(root: root, expanded: ["root", "system"])
    #expect(open.map(\.id) == ["root", "system", "planet"])
    #expect(open.last?.parentID == "system")
    #expect(open.last?.x == 520)
}

@Test func mindMapPagesLargeBranchesWithoutDroppingTheirIdentity() {
    let root = MindMapBranch(id: "city", children: (0..<1000).map { .init(id: "p\($0)") })
    let first = ReadOnlyMindMapLayout.make(root: root, expanded: ["city"])
    #expect(first.count == 26)
    #expect(first.last?.moreForParentID == "city")
    #expect(first.filter { $0.id.hasPrefix("p") }.count == 24)
    let next = ReadOnlyMindMapLayout.make(root: root, expanded: ["city"], limits: ["city": 48])
    #expect(next.count == 50)
    #expect(next.contains { $0.id == "p47" })
    let all = ReadOnlyMindMapLayout.make(root: root, expanded: ["city"], limits: ["city": 1000])
    #expect(all.count == 1001)
    #expect(all.allSatisfy { $0.moreForParentID == nil })
}

@Test func mindMapLayoutIsDeterministicAndLeavesDoNotOverlap() {
    let root = MindMapBranch(id: "root", children: [
        .init(id: "a", children: [.init(id: "a1"), .init(id: "a2")]),
        .init(id: "b", children: [.init(id: "b1")])
    ])
    let expanded: Set<String> = ["root", "a", "b"]
    let first = ReadOnlyMindMapLayout.make(root: root, expanded: expanded)
    let second = ReadOnlyMindMapLayout.make(root: root, expanded: expanded)
    #expect(first.map(\.id) == second.map(\.id))
    #expect(first.map(\.y) == second.map(\.y))
    let leaves = first.filter { ["a1", "a2", "b1"].contains($0.id) }
    #expect(Set(leaves.map(\.y)).count == 3)
    #expect(first.first?.y == 110)
    #expect(ReadOnlyMindMapLayout.make(root: root, expanded: ["root"]).map(\.id) == ["root", "a", "b"])
}

@Test func mindMapFocusCentersReadableAnchorWithoutShrinkingForAllChildren() throws {
    let root = MindMapBranch(id: "root", children: [.init(id: "focus", children: (0..<24).map { .init(id: "p\($0)") })])
    let positions = ReadOnlyMindMapLayout.make(root: root, expanded: ["root", "focus"])
    for height in [220.0, 480.0, 800.0] {
        let camera = try #require(ReadOnlyMindMapLayout.focus(id: "focus", placements: positions, width: 360, height: height))
        let anchor = try #require(positions.first { $0.id == "focus" })
        #expect(abs(anchor.x * camera.zoom + camera.offsetX) < 0.0001)
        #expect(abs(anchor.y * camera.zoom + camera.offsetY) < 0.0001)
        #expect(camera.zoom == 1.2)
        for point in positions where point.id == "focus" {
            let x = 180 + point.x * camera.zoom + camera.offsetX
            let y = height / 2 + point.y * camera.zoom + camera.offsetY
            #expect(x - 106 * camera.zoom >= 15.9)
            #expect(x + 106 * camera.zoom <= 344.1)
            #expect(y - 34 * camera.zoom >= 15.9)
            #expect(y + 34 * camera.zoom <= height - 15.9)
        }
    }
    #expect(ReadOnlyMindMapLayout.focus(id: "missing", placements: positions, width: 360, height: 400) == nil)
    #expect(ReadOnlyMindMapLayout.focus(id: "focus", placements: positions, width: 0, height: 0) == nil)
    let collapsed = ReadOnlyMindMapLayout.make(root: root, expanded: ["root"])
    let closedCamera = try #require(ReadOnlyMindMapLayout.focus(id: "focus", placements: collapsed, width: 360, height: 480))
    let openCamera = try #require(ReadOnlyMindMapLayout.focus(id: "focus", placements: positions, width: 360, height: 480))
    #expect(closedCamera.zoom == openCamera.zoom)
    let narrow = try #require(ReadOnlyMindMapLayout.focus(id: "focus", placements: positions, width: 240, height: 180))
    #expect(narrow.zoom * 212 <= 208.001)
}
