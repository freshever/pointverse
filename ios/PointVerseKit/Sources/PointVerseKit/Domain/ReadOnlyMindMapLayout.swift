import Foundation

public struct MindMapBranch: Sendable {
    public let id: String
    public let children: [MindMapBranch]
    public init(id: String, children: [MindMapBranch] = []) { self.id = id; self.children = children }
}

public struct MindMapPlacement: Sendable {
    public let id: String
    public let parentID: String?
    public let x: Double
    public let y: Double
    /// A synthetic "show more" node, not a persisted content node.
    public let moreForParentID: String?
}

public enum ReadOnlyMindMapLayout {
    public struct Camera: Sendable {
        public let zoom: Double
        public let offsetX: Double
        public let offsetY: Double
    }

    /// Focus is a readable local view, not a fit of the entire expanded branch.
    /// Keep the selected card centered; offscreen neighbors remain available by panning.
    public static func focus(id: String, placements: [MindMapPlacement], width: Double, height: Double) -> Camera? {
        guard width > 0, height > 0, let anchor = placements.first(where: { $0.id == id }) else { return nil }
        // Nominal 14pt labels become 16.8pt at 1.2x. Only shrink for a viewport
        // too small to contain the selected card itself, never for sibling count.
        let zoom = min(1.2, max(0.001, min(max(1, width - 32) / 212, max(1, height - 32) / 68)))
        return Camera(zoom: zoom, offsetX: -anchor.x * zoom, offsetY: -anchor.y * zoom)
    }

    /// Ordered tidy tree. Only expanded branches are traversed; large sibling lists are paged.
    public static func make(root: MindMapBranch, expanded: Set<String>, limits: [String: Int] = [:]) -> [MindMapPlacement] {
        var result: [MindMapPlacement] = []
        var nextY = 0.0
        func visit(_ node: MindMapBranch, parent: String?, depth: Int) -> Double {
            let index = result.count
            result.append(.init(id: node.id, parentID: parent, x: Double(depth) * 260, y: 0, moreForParentID: nil))
            var childY: [Double] = []
            if expanded.contains(node.id), !node.children.isEmpty {
                let limit = max(1, limits[node.id] ?? 24)
                for child in node.children.prefix(limit) { childY.append(visit(child, parent: node.id, depth: depth + 1)) }
                if node.children.count > limit {
                    let y = nextY; nextY += 88
                    result.append(.init(id: "mindmap-more:" + node.id, parentID: node.id,
                                        x: Double(depth + 1) * 260, y: y, moreForParentID: node.id))
                    childY.append(y)
                }
            }
            let y: Double
            if let first = childY.first, let last = childY.last { y = (first + last) / 2 }
            else { y = nextY; nextY += 88 }
            result[index] = .init(id: node.id, parentID: parent, x: Double(depth) * 260, y: y, moreForParentID: nil)
            return y
        }
        _ = visit(root, parent: nil, depth: 0)
        return result
    }
}
