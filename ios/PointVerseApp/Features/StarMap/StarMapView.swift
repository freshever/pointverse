import NaturalLanguage
import PointVerseKit
import SwiftUI

struct StarMapView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var layout = StarLayout(nodes: [], links: [])
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
            layout = StarLayoutEngine.make(entries: try await container.database.pointMapEntries())
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

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Canvas { context, size in
                    let projected = project(size: size)

                    for link in layout.links {
                        guard projected.indices.contains(link.a), projected.indices.contains(link.b) else { continue }
                        var path = Path()
                        path.move(to: projected[link.a].point)
                        path.addLine(to: projected[link.b].point)
                        context.stroke(path, with: .color(.white.opacity(Double(0.08 + link.strength * 0.28))), lineWidth: 1)
                    }

                    for node in projected.sorted(by: { $0.depth < $1.depth }) {
                        let point = layout.nodes[node.index].point
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
                        selectNearest(to: value.location, size: proxy.size)
                    }
                )

                VStack {
                    HStack {
                        Label("\(layout.nodes.count) 个想法", systemImage: "circle.hexagongrid.fill")
                        Spacer()
                        Text("拖动旋转 · 双指缩放")
                    }
                    .font(.caption).foregroundStyle(.white.opacity(0.7)).padding()
                    Spacer()
                    HStack(spacing: 10) {
                        Text("视角").font(.caption).foregroundStyle(.white.opacity(0.65))
                        axisButton("X", color: .red, yaw: -.pi / 2, pitch: 0)
                        axisButton("Y", color: .green, yaw: 0, pitch: .pi / 2)
                        axisButton("Z", color: .blue, yaw: 0, pitch: 0)
                    }
                    .padding(10)
                    .background(.black.opacity(0.7), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.25)))
                    .padding(.bottom, 18)
                }
            }
        }
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

    private func selectNearest(to location: CGPoint, size: CGSize) {
        let nodes = project(size: size)
        guard let nearest = nodes.min(by: {
            hypot($0.point.x - location.x, $0.point.y - location.y) < hypot($1.point.x - location.x, $1.point.y - location.y)
        }), hypot(nearest.point.x - location.x, nearest.point.y - location.y) <= max(34, nearest.radius + 18) else { return }
        onSelect(layout.nodes[nearest.index].point)
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
    struct Node { let point: PointSummary; let position: Point3D }
    struct Link { let a: Int; let b: Int; let strength: CGFloat }
}

@MainActor
private enum StarLayoutEngine {
    static func make(entries: [PointMapEntry]) -> StarLayout {
        guard !entries.isEmpty else { return .init(nodes: [], links: []) }
        let vectors = entries.map { semanticVector(text: $0.content, locale: $0.localeIdentifier) }
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
            for j in candidates.prefix(2) where similarities[i][j] >= 0.28 {
                let a = min(i, j), b = max(i, j)
                if used.insert("\(a):\(b)").inserted { links.append(.init(a: a, b: b, strength: similarities[i][j])) }
            }
        }
        return .init(nodes: zip(entries, positions).map { .init(point: $0.0.point, position: $0.1) }, links: links)
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
