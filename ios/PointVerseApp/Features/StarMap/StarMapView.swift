import NaturalLanguage
import PointVerseKit
import SwiftUI

struct StarMapView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var layout = StarLayout(nodes: [], links: [], embeddingCount: 0)
    @State private var selected: PointSummary?
    @State private var loadFailed = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.035, green: 0.045, blue: 0.11), .black],
                startPoint: .top,
                endPoint: .bottom
            ).ignoresSafeArea()

            if layout.nodes.isEmpty {
                ContentUnavailableView {
                    Label("等待第一颗星", systemImage: "sparkles")
                } description: {
                    Text("保存第一条想法，它会出现在你的私人星图中。")
                }
                .foregroundStyle(.white)
            } else {
                Pseudo3DStarMap(layout: layout) { selected = $0 }
            }
        }
        .navigationTitle("星图")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(Color(red: 0.035, green: 0.045, blue: 0.11), for: .navigationBar)
        .toolbar {
            Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                .tint(.white)
        }
        .task { await reload() }
        .sheet(item: $selected) { point in
            NavigationStack { PointDetailView(point: point) }
                .environmentObject(container)
                .presentationDetents([.medium, .large])
        }
        .alert("无法读取星图", isPresented: $loadFailed) { Button("好") {} }
    }

    private func reload() async {
        do {
            async let entries = container.database.pointMapEntries()
            async let embeddings = container.database.embeddings(modelID: EmbeddingModelIdentity.bgeSmallZhV15)
            layout = StarLayoutEngine.make(entries: try await entries, embeddings: try await embeddings)
        } catch {
            loadFailed = true
        }
    }
}

private struct Pseudo3DStarMap: View {
    let layout: StarLayout
    let onSelect: (PointSummary) -> Void
    @State private var yaw: CGFloat = 0.35
    @State private var pitch: CGFloat = -0.18
    @State private var dragStartYaw: CGFloat?
    @State private var dragStartPitch: CGFloat?
    @State private var zoom: CGFloat = 1
    @State private var zoomStart: CGFloat?
    @State private var selectedLink: StarLayout.Link?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Canvas { context, size in
                    let projected = project(size: size)
                    let clusters = displayClusters(projected: projected)
                    let clusterByNode = Dictionary(uniqueKeysWithValues: clusters.flatMap { cluster in
                        cluster.nodeIndices.map { ($0, cluster) }
                    })
                    var drawnClusterLinks = Set<String>()

                    for link in layout.links {
                        guard let first = clusterByNode[link.a], let second = clusterByNode[link.b],
                              first.id != second.id else { continue }
                        let key = first.id < second.id ? "\(first.id):\(second.id)" : "\(second.id):\(first.id)"
                        guard drawnClusterLinks.insert(key).inserted else { continue }
                        var path = Path()
                        path.move(to: first.point)
                        path.addLine(to: second.point)
                        let emphasis = max(0, min(1, (link.strength - 0.85) / 0.12))
                        context.stroke(path, with: .color(linkColor(link.strength).opacity(Double(0.45 + emphasis * 0.45))),
                                       style: StrokeStyle(lineWidth: 1.2 + emphasis * 2.2, lineCap: .round,
                                                          dash: [5, 5]))
                    }

                    for cluster in clusters.sorted(by: { $0.depth < $1.depth }) {
                        if cluster.nodeIndices.count > 1 {
                            let rect = CGRect(x: cluster.point.x - cluster.radius, y: cluster.point.y - cluster.radius,
                                              width: cluster.radius * 2, height: cluster.radius * 2)
                            context.fill(Path(ellipseIn: rect), with: .radialGradient(
                                Gradient(colors: [.cyan.opacity(0.95), .indigo.opacity(0.72)]),
                                center: cluster.point, startRadius: 1, endRadius: cluster.radius
                            ))
                            context.stroke(Path(ellipseIn: rect.insetBy(dx: -4, dy: -4)),
                                           with: .color(.cyan.opacity(0.35)), lineWidth: 2)
                            context.draw(
                                Text("\(cluster.nodeIndices.count)").font(.headline.bold()).foregroundStyle(.white),
                                at: cluster.point, anchor: .center
                            )
                            context.draw(
                                Text("相关想法").font(.caption2).foregroundStyle(.white.opacity(0.75)),
                                at: CGPoint(x: cluster.point.x, y: cluster.point.y + cluster.radius + 11), anchor: .center
                            )
                            continue
                        }
                        guard let index = cluster.nodeIndices.first else { continue }
                        let node = projected[index]
                        let point = layout.nodes[index].point
                        let color: Color = point.transcriptState == "failed"
                            ? .orange
                            : Date().timeIntervalSince(point.createdAt) < 86_400 * 7 ? .cyan : .indigo
                        let rect = CGRect(
                            x: node.point.x - node.radius,
                            y: node.point.y - node.radius,
                            width: node.radius * 2,
                            height: node.radius * 2
                        )
                        context.fill(Path(ellipseIn: rect), with: .color(color))
                        context.stroke(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)), with: .color(color.opacity(0.25)), lineWidth: 2)
                        if layout.nodes[index].isEmbedded {
                            context.stroke(
                                Path(ellipseIn: rect.insetBy(dx: -6, dy: -6)),
                                with: .color(.mint.opacity(0.72)),
                                lineWidth: 1.5
                            )
                        }

                        if !point.title.isEmpty {
                            let label = Text(String(point.title.prefix(12)))
                                .font(.caption2).foregroundStyle(.white.opacity(0.78))
                            context.draw(label, at: CGPoint(x: node.point.x, y: node.point.y + node.radius + 11), anchor: .center)
                        }
                    }
                }
                .contentShape(Rectangle())
                .gesture(rotationGesture)
                .simultaneousGesture(zoomGesture)
                .simultaneousGesture(
                    SpatialTapGesture().onEnded { value in
                        handleTap(at: value.location, size: proxy.size)
                    }
                )

                VStack {
                    VStack(spacing: 8) {
                        HStack {
                            Label("\(layout.nodes.count) 个想法", systemImage: "circle.hexagongrid.fill")
                            Spacer()
                            Text("拖动旋转 · 双指缩放")
                        }
                        semanticStatus
                    }
                    .font(.caption).foregroundStyle(.white.opacity(0.7)).padding()
                    Spacer()
                    VStack(spacing: 10) {
                        if let selectedLink {
                            relationCard(selectedLink, selected: true)
                        } else if let strongest = layout.strongestLink {
                            relationCard(strongest, selected: false)
                        }
                        HStack(spacing: 10) {
                            zoomButton(systemName: "minus.magnifyingglass", factor: 0.8)
                            zoomButton(systemName: "plus.magnifyingglass", factor: 1.25)
                            Divider().frame(height: 22).overlay(.white.opacity(0.2))
                            Text("视角").font(.caption).foregroundStyle(.white.opacity(0.65))
                            axisButton("X", color: .red, yaw: -.pi / 2, pitch: 0)
                            axisButton("Y", color: .green, yaw: 0, pitch: .pi / 2)
                            axisButton("Z", color: .blue, yaw: 0, pitch: 0)
                        }
                        .padding(10)
                        .background(.black.opacity(0.7), in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(0.25)))
                    }
                    .padding(.bottom, 18)
                }
            }
        }
    }

    private var semanticStatus: some View {
        VStack(spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: layout.usesBGE ? "sparkles" : "bolt.trianglebadge.exclamationmark")
                Text(layout.usesBGE ? "E5 多语言语义分析" : "系统语义分析")
                    .fontWeight(.semibold)
                Spacer()
                Text(layout.usesBGE ? "\(layout.embeddingCount)/\(layout.nodes.count) 已完成" : "E5 未启用")
            }
            if layout.usesBGE {
                HStack(spacing: 12) {
                    legendDot(.indigo, "低候选")
                    legendDot(.cyan, "中候选")
                    legendDot(.mint, "高候选")
                    Spacer()
                    Text("点虚线看分数").foregroundStyle(.white.opacity(0.55))
                }
                .font(.caption2)
            }
        }
        .foregroundStyle(layout.usesBGE ? Color.mint : Color.orange)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke((layout.usesBGE ? Color.mint : Color.orange).opacity(0.35)))
    }

    private func legendDot(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).foregroundStyle(.white.opacity(0.68))
        }
    }

    private func relationCard(_ link: StarLayout.Link, selected: Bool) -> some View {
        let first = layout.nodes[link.a].point.title
        let second = layout.nodes[link.b].point.title
        return Button {
            if selected { selectedLink = nil } else { selectedLink = link }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(linkColor(link.strength))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(selected ? "当前候选" : "最高候选") · E5 系数 \(link.strength, format: .number.precision(.fractionLength(3)))")
                        .font(.caption.bold()).foregroundStyle(.white)
                    Text("\(first)  ↔  \(second)")
                        .font(.caption2).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
                Spacer()
                Text(relationLevel(link.strength)).font(.caption2.bold()).foregroundStyle(linkColor(link.strength))
                Image(systemName: selected ? "xmark.circle.fill" : "hand.tap")
                    .font(.caption).foregroundStyle(.white.opacity(0.5))
            }
            .padding(12)
            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(linkColor(link.strength).opacity(0.4)))
            .padding(.horizontal)
        }
        .buttonStyle(.plain)
    }

    private func zoomButton(systemName: String, factor: CGFloat) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) { zoom = min(2.2, max(0.55, zoom * factor)) }
        } label: {
            Image(systemName: systemName).foregroundStyle(.white)
                .frame(width: 32, height: 32).background(.white.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
    }

    private func linkColor(_ score: CGFloat) -> Color {
        score >= 0.94 ? .mint : score >= 0.89 ? .cyan : .indigo
    }

    private func relationLevel(_ score: CGFloat) -> String {
        score >= 0.94 ? "高候选" : score >= 0.89 ? "中候选" : "低候选"
    }

    private var rotationGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if dragStartYaw == nil { dragStartYaw = yaw; dragStartPitch = pitch }
                yaw = (dragStartYaw ?? yaw) + value.translation.width * 0.008
                pitch = min(.pi / 2, max(-.pi / 2, (dragStartPitch ?? pitch) + value.translation.height * 0.008))
            }
            .onEnded { _ in dragStartYaw = nil; dragStartPitch = nil }
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if zoomStart == nil { zoomStart = zoom }
                zoom = min(2.2, max(0.55, (zoomStart ?? zoom) * value))
            }
            .onEnded { _ in zoomStart = nil }
    }

    private func axisButton(_ title: String, color: Color, yaw targetYaw: CGFloat, pitch targetPitch: CGFloat) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.35)) { yaw = targetYaw; pitch = targetPitch }
        } label: {
            Text(title).font(.caption.bold()).foregroundStyle(.white)
                .frame(width: 32, height: 32).background(color, in: Circle())
        }.buttonStyle(.plain)
    }

    private func handleTap(at location: CGPoint, size: CGSize) {
        let nodes = project(size: size)
        let clusters = displayClusters(projected: nodes)
        if let nearest = clusters.min(by: {
            hypot($0.point.x - location.x, $0.point.y - location.y) < hypot($1.point.x - location.x, $1.point.y - location.y)
        }), hypot(nearest.point.x - location.x, nearest.point.y - location.y) <= max(34, nearest.radius + 14) {
            if nearest.nodeIndices.count > 1 {
                selectedLink = nil
                withAnimation(.easeInOut(duration: 0.3)) { zoom = min(2.2, max(1.12, zoom * 1.45)) }
            } else if let index = nearest.nodeIndices.first {
                onSelect(layout.nodes[index].point)
            }
            return
        }
        let clusterByNode = Dictionary(uniqueKeysWithValues: clusters.flatMap { cluster in
            cluster.nodeIndices.map { ($0, cluster) }
        })
        let visibleLinks = layout.links.filter {
            clusterByNode[$0.a]?.id != clusterByNode[$0.b]?.id
        }
        selectedLink = visibleLinks.min(by: {
            distance(from: location, to: $0, clusters: clusterByNode) < distance(from: location, to: $1, clusters: clusterByNode)
        }).flatMap { distance(from: location, to: $0, clusters: clusterByNode) <= 18 ? $0 : nil }
    }

    private func displayClusters(projected: [ProjectedNode]) -> [DisplayCluster] {
        let threshold: CGFloat
        switch zoom {
        case 1.55...: threshold = .infinity
        case 1.18..<1.55: threshold = 0.94
        case 0.88..<1.18: threshold = 0.89
        default: threshold = 0.85
        }
        var remaining = Set(layout.nodes.indices)
        var groups: [[Int]] = []
        while let seed = remaining.first {
            remaining.remove(seed)
            var group = [seed], queue = [seed]
            while let current = queue.popLast() {
                for link in layout.links where link.strength >= threshold {
                    let neighbor: Int?
                    if link.a == current { neighbor = link.b }
                    else if link.b == current { neighbor = link.a }
                    else { neighbor = nil }
                    if let neighbor, remaining.remove(neighbor) != nil {
                        group.append(neighbor); queue.append(neighbor)
                    }
                }
            }
            groups.append(group)
        }
        return groups.enumerated().map { id, indices in
            let members = indices.map { projected[$0] }
            let count = CGFloat(members.count)
            return DisplayCluster(
                id: id,
                nodeIndices: indices,
                point: CGPoint(x: members.reduce(0) { $0 + $1.point.x } / count,
                               y: members.reduce(0) { $0 + $1.point.y } / count),
                depth: members.reduce(0) { $0 + $1.depth } / count,
                radius: members.count == 1 ? members[0].radius : min(28, 12 + sqrt(count) * 4)
            )
        }
    }

    private func distance(from point: CGPoint, to link: StarLayout.Link, clusters: [Int: DisplayCluster]) -> CGFloat {
        guard let a = clusters[link.a]?.point, let b = clusters[link.b]?.point else { return .infinity }
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }

    private func project(size: CGSize) -> [ProjectedNode] {
        let cosY = cos(yaw), sinY = sin(yaw), cosX = cos(pitch), sinX = sin(pitch)
        let baseScale = min(size.width, size.height) * 0.055 * zoom
        return layout.nodes.enumerated().map { index, node in
            let p = node.position
            let x1 = p.x * cosY + p.z * sinY
            let z1 = -p.x * sinY + p.z * cosY
            let y1 = p.y * cosX - z1 * sinX
            let z2 = p.y * sinX + z1 * cosX
            let perspective = max(0.42, min(1.8, 15 / (15 - z2)))
            return ProjectedNode(
                index: index,
                point: CGPoint(x: size.width / 2 + x1 * baseScale * perspective,
                               y: size.height / 2 - y1 * baseScale * perspective),
                depth: z2,
                radius: max(6, 9 * perspective)
            )
        }
    }
}

private struct ProjectedNode {
    let index: Int
    let point: CGPoint
    let depth: CGFloat
    let radius: CGFloat
}

private struct DisplayCluster: Identifiable {
    let id: Int
    let nodeIndices: [Int]
    let point: CGPoint
    let depth: CGFloat
    let radius: CGFloat
}

private struct Point3D {
    var x: CGFloat
    var y: CGFloat
    var z: CGFloat
    static func + (lhs: Self, rhs: Self) -> Self { .init(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z) }
    static func - (lhs: Self, rhs: Self) -> Self { .init(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z) }
    static func * (lhs: Self, rhs: CGFloat) -> Self { .init(x: lhs.x * rhs, y: lhs.y * rhs, z: lhs.z * rhs) }
    var length: CGFloat { sqrt(x * x + y * y + z * z) }
    var normalized: Self { self * (1 / max(length, 0.001)) }
}

private struct StarLayout {
    let nodes: [Node]
    let links: [Link]
    let embeddingCount: Int
    var usesBGE: Bool { embeddingCount > 0 }
    var strongestLink: Link? { links.max { $0.strength < $1.strength } }
    struct Node { let point: PointSummary; let position: Point3D; let isEmbedded: Bool }
    struct Link { let a: Int; let b: Int; let strength: CGFloat }
}

@MainActor
private enum StarLayoutEngine {
    static func make(entries: [PointMapEntry], embeddings: [PointEmbeddingRecord]) -> StarLayout {
        guard !entries.isEmpty else { return .init(nodes: [], links: [], embeddingCount: 0) }
        let stored = Dictionary(uniqueKeysWithValues: embeddings.map { ($0.pointID, $0.vector.map(Double.init)) })
        let vectors = entries.map { stored[$0.id] ?? semanticVector(text: $0.content, locale: $0.localeIdentifier) }
        var similarities = Array(repeating: Array(repeating: CGFloat(0), count: entries.count), count: entries.count)
        for i in entries.indices {
            for j in entries.indices where j > i {
                let value = CGFloat(cosine(vectors[i], vectors[j]) ?? lexicalSimilarity(entries[i].content, entries[j].content))
                similarities[i][j] = max(0, value); similarities[j][i] = similarities[i][j]
            }
        }

        var positions = entries.map { initialPosition(id: $0.id) }
        for iteration in 0..<120 where entries.count > 1 {
            var forces = Array(repeating: Point3D(x: 0, y: 0, z: 0), count: entries.count)
            for i in entries.indices {
                for j in entries.indices where j > i {
                    let delta = positions[j] - positions[i]
                    let distance = max(delta.length, 0.18)
                    let direction = delta.normalized
                    let repulsion = 0.055 / (distance * distance)
                    forces[i] = forces[i] - direction * repulsion
                    forces[j] = forces[j] + direction * repulsion
                    let relatedness = similarities[i][j]
                    if relatedness >= 0.22 {
                        let target = 1.4 + (1 - relatedness) * 5.2
                        let attraction = (distance - target) * (0.006 + relatedness * 0.018)
                        forces[i] = forces[i] + direction * attraction
                        forces[j] = forces[j] - direction * attraction
                    }
                }
                forces[i] = forces[i] - positions[i] * 0.0025
            }
            let cooling = CGFloat(120 - iteration) / 120
            for i in positions.indices {
                positions[i] = positions[i] + forces[i] * max(0.22, cooling)
                if positions[i].length > 9 { positions[i] = positions[i].normalized * 9 }
            }
        }

        var links: [StarLayout.Link] = [], used = Set<String>()
        for i in entries.indices {
            let candidates = entries.indices.filter { $0 != i }.sorted { similarities[i][$0] > similarities[i][$1] }
            for j in candidates {
                let bothEmbedded = stored[entries[i].id] != nil && stored[entries[j].id] != nil
                let threshold: CGFloat = bothEmbedded ? 0.85 : (stored.isEmpty ? 0.28 : .infinity)
                guard similarities[i][j] >= threshold else { continue }
                let a = min(i, j), b = max(i, j)
                if used.insert("\(a):\(b)").inserted {
                    links.append(.init(a: a, b: b, strength: similarities[i][j]))
                }
            }
        }
        return .init(
            nodes: zip(entries, positions).map {
                .init(point: $0.0.point, position: $0.1, isEmbedded: stored[$0.0.id] != nil)
            },
            links: links,
            embeddingCount: stored.count
        )
    }

    private static func semanticVector(text: String, locale: String) -> [Double]? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let value = locale.replacingOccurrences(of: "_", with: "-").lowercased()
        let language: NLLanguage = value.hasPrefix("zh-hant") || value.hasPrefix("zh-tw") ? .traditionalChinese
            : value.hasPrefix("zh") ? .simplifiedChinese : value.hasPrefix("ja") ? .japanese : .english
        return NLEmbedding.sentenceEmbedding(for: language)?.vector(for: cleaned)
    }

    private static func cosine(_ lhs: [Double]?, _ rhs: [Double]?) -> Double? {
        guard let lhs, let rhs, lhs.count == rhs.count, !lhs.isEmpty else { return nil }
        var dot = 0.0, left = 0.0, right = 0.0
        for i in lhs.indices { dot += lhs[i] * rhs[i]; left += lhs[i] * lhs[i]; right += rhs[i] * rhs[i] }
        return left > 0 && right > 0 ? dot / sqrt(left * right) : nil
    }

    private static func lexicalSimilarity(_ lhs: String, _ rhs: String) -> Double {
        func grams(_ text: String) -> Set<String> {
            let chars = Array(text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation })
            guard chars.count > 1 else { return Set(chars.map(String.init)) }
            return Set((0..<(chars.count - 1)).map { String(chars[$0...($0 + 1)]) })
        }
        let a = grams(lhs), b = grams(rhs)
        return a.isEmpty || b.isEmpty ? 0 : Double(a.intersection(b).count) / Double(a.union(b).count)
    }

    private static func initialPosition(id: PointID) -> Point3D {
        let bytes = withUnsafeBytes(of: id.rawValue.uuid) { Array($0) }
        func unit(_ offset: Int) -> CGFloat { CGFloat((Int(bytes[offset]) << 8) | Int(bytes[offset + 1])) / 65_535 }
        let theta = unit(0) * .pi * 2, phi = acos(2 * unit(2) - 1), radius: CGFloat = 4.5
        return .init(x: radius * sin(phi) * cos(theta), y: radius * cos(phi), z: radius * sin(phi) * sin(theta))
    }
}
