import NaturalLanguage
import PointVerseKit
import SceneKit
import SwiftUI

struct StarMapView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var layout = StarLayout(nodes: [], links: [])
    @State private var selected: PointSummary?
    @State private var loadFailed = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.025, green: 0.035, blue: 0.09), .black], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            if layout.nodes.isEmpty {
                ContentUnavailableView {
                    Label("等待第一颗星", systemImage: "sparkles")
                } description: {
                    Text("保存第一条想法，它会出现在你的私人星图中。")
                }
                .foregroundStyle(.white)
            } else {
                StarSceneView(layout: layout) { selected = $0 }
                    .ignoresSafeArea(edges: .bottom)
                VStack {
                    HStack {
                        Label("\(layout.nodes.count) 个想法", systemImage: "circle.hexagongrid.fill")
                        Spacer()
                        Text("拖动旋转 · 双指缩放")
                    }
                    .font(.caption).foregroundStyle(.white.opacity(0.7)).padding()
                    Spacer()
                }
            }
        }
        .navigationTitle("星图")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(Color(red: 0.025, green: 0.035, blue: 0.09), for: .navigationBar)
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
            let entries = try await container.database.pointMapEntries()
            layout = StarLayoutEngine.make(entries: entries)
        }
        catch { loadFailed = true }
    }
}

private struct StarSceneView: UIViewRepresentable {
    let layout: StarLayout
    let onSelect: (PointSummary) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.scene = makeScene()
        view.allowsCameraControl = false
        view.antialiasingMode = .multisampling4X
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.didTap(_:)))
        tap.numberOfTapsRequired = 1
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.didPan(_:)))
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.didPinch(_:)))
        pinch.delegate = context.coordinator
        view.addGestureRecognizer(pinch)
        context.coordinator.points = Dictionary(uniqueKeysWithValues: layout.nodes.map { ($0.point.id.rawValue.uuidString, $0.point) })
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.onSelect = onSelect
        context.coordinator.points = Dictionary(uniqueKeysWithValues: layout.nodes.map { ($0.point.id.rawValue.uuidString, $0.point) })
        view.scene = makeScene()
    }

    private func makeScene() -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = UIColor.clear
        let positions = layout.nodes.map(\.position)
        let content = SCNNode()
        content.name = "__star_content"
        scene.rootNode.addChildNode(content)

        for (index, layoutNode) in layout.nodes.enumerated() {
            let point = layoutNode.point
            let sphere = SCNSphere(radius: point.transcriptState == "succeeded" ? 0.22 : 0.16)
            sphere.segmentCount = 18
            let material = SCNMaterial()
            material.diffuse.contents = color(for: point)
            material.emission.contents = color(for: point).withAlphaComponent(0.65)
            material.lightingModel = .constant
            sphere.materials = [material]
            let node = SCNNode(geometry: sphere)
            node.position = positions[index]
            node.name = point.id.rawValue.uuidString

            let glow = SCNParticleSystem()
            glow.birthRate = 9
            glow.particleLifeSpan = 1.4
            glow.particleSize = 0.035
            glow.particleColor = color(for: point)
            glow.emitterShape = sphere
            node.addParticleSystem(glow)
            content.addChildNode(node)
        }

        for link in layout.links {
            content.addChildNode(line(from: positions[link.a], to: positions[link.b], strength: link.strength))
        }

        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.zFar = 100
        camera.position = SCNVector3(0, 0, 18)
        scene.rootNode.addChildNode(camera)

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 180
        let light = SCNNode()
        light.light = ambient
        scene.rootNode.addChildNode(light)
        return scene
    }

    private func color(for point: PointSummary) -> UIColor {
        if point.transcriptState == "failed" { return UIColor.systemOrange }
        let age = Date().timeIntervalSince(point.createdAt)
        return age < 86_400 * 7 ? UIColor.systemCyan : UIColor(red: 0.55, green: 0.48, blue: 1, alpha: 1)
    }

    private func line(from start: SCNVector3, to end: SCNVector3, strength: Float) -> SCNNode {
        let vector = SCNVector3(end.x - start.x, end.y - start.y, end.z - start.z)
        let length = sqrt(vector.x * vector.x + vector.y * vector.y + vector.z * vector.z)
        let cylinder = SCNCylinder(radius: 0.008, height: CGFloat(length))
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.white.withAlphaComponent(CGFloat(0.08 + strength * 0.32))
        material.lightingModel = .constant
        cylinder.materials = [material]
        let node = SCNNode(geometry: cylinder)
        node.position = SCNVector3((start.x + end.x) / 2, (start.y + end.y) / 2, (start.z + end.z) / 2)
        node.eulerAngles = SCNVector3(Float.pi / 2, acos(vector.z / length), atan2(vector.y, vector.x))
        return node
    }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onSelect: (PointSummary) -> Void
        var points: [String: PointSummary] = [:]
        private var lastPanTranslation = CGPoint.zero
        init(onSelect: @escaping (PointSummary) -> Void) { self.onSelect = onSelect }

        @objc func didTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? SCNView else { return }
            let location = gesture.location(in: view)
            for hit in view.hitTest(location, options: [.boundingBoxOnly: true, .searchMode: SCNHitTestSearchMode.all.rawValue]) {
                var node: SCNNode? = hit.node
                while let current = node {
                    if let name = current.name, let point = points[name] { onSelect(point); return }
                    node = current.parent
                }
            }

            // 星体在远景时很小；允许点中屏幕上最近的一颗星。
            var nearest: (point: PointSummary, distance: CGFloat)?
            view.scene?.rootNode.enumerateChildNodes { node, _ in
                guard let name = node.name, let point = self.points[name] else { return }
                let projected = view.projectPoint(node.worldPosition)
                guard projected.z >= 0, projected.z <= 1 else { return }
                let distance = hypot(CGFloat(projected.x) - location.x, CGFloat(projected.y) - location.y)
                if distance < 44, distance < (nearest?.distance ?? .greatestFiniteMagnitude) {
                    nearest = (point, distance)
                }
            }
            if let nearest { onSelect(nearest.point) }
        }

        @objc func didPan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view as? SCNView,
                  let content = view.scene?.rootNode.childNode(withName: "__star_content", recursively: false) else { return }
            let translation = gesture.translation(in: view)
            if gesture.state == .began { lastPanTranslation = .zero }
            let dx = translation.x - lastPanTranslation.x
            let dy = translation.y - lastPanTranslation.y
            content.eulerAngles.y += Float(dx) * 0.008
            content.eulerAngles.x += Float(dy) * 0.008
            lastPanTranslation = translation
        }

        @objc func didPinch(_ gesture: UIPinchGestureRecognizer) {
            guard let camera = (gesture.view as? SCNView)?.pointOfView else { return }
            camera.position.z = min(30, max(8, camera.position.z / Float(gesture.scale)))
            gesture.scale = 1
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

private struct StarLayout {
    let nodes: [Node]
    let links: [Link]

    struct Node {
        let point: PointSummary
        let position: SCNVector3
    }

    struct Link {
        let a: Int
        let b: Int
        let strength: Float
    }
}

@MainActor
private enum StarLayoutEngine {
    private struct Vector3 {
        var x: Float
        var y: Float
        var z: Float

        static func + (lhs: Self, rhs: Self) -> Self { .init(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z) }
        static func - (lhs: Self, rhs: Self) -> Self { .init(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z) }
        static func * (lhs: Self, rhs: Float) -> Self { .init(x: lhs.x * rhs, y: lhs.y * rhs, z: lhs.z * rhs) }
        var length: Float { sqrt(x * x + y * y + z * z) }
        var normalized: Self { let value = max(length, 0.001); return self * (1 / value) }
    }

    static func make(entries: [PointMapEntry]) -> StarLayout {
        guard !entries.isEmpty else { return StarLayout(nodes: [], links: []) }
        let vectors = entries.map { semanticVector(text: $0.content, locale: $0.localeIdentifier) }
        var similarity = Array(repeating: Array(repeating: Float(0), count: entries.count), count: entries.count)
        for i in entries.indices {
            for j in entries.indices where j > i {
                let value = Float(cosine(vectors[i], vectors[j]) ?? lexicalSimilarity(entries[i].content, entries[j].content))
                similarity[i][j] = max(0, value)
                similarity[j][i] = similarity[i][j]
            }
        }

        var positions = entries.map { initialPosition(id: $0.id) }
        if entries.count > 1 {
            for iteration in 0..<120 {
                var forces = Array(repeating: Vector3(x: 0, y: 0, z: 0), count: entries.count)
                for i in entries.indices {
                    for j in entries.indices where j > i {
                        let delta = positions[j] - positions[i]
                        let distance = max(delta.length, 0.18)
                        let direction = delta.normalized
                        let repulsion = 0.055 / (distance * distance)
                        forces[i] = forces[i] - direction * repulsion
                        forces[j] = forces[j] + direction * repulsion

                        let relatedness = similarity[i][j]
                        if relatedness >= 0.22 {
                            let targetDistance = 1.4 + (1 - relatedness) * 5.2
                            let attraction = (distance - targetDistance) * (0.006 + relatedness * 0.018)
                            forces[i] = forces[i] + direction * attraction
                            forces[j] = forces[j] - direction * attraction
                        }
                    }
                    forces[i] = forces[i] - positions[i] * 0.0025
                }
                let cooling = Float(120 - iteration) / 120
                for i in positions.indices {
                    positions[i] = positions[i] + forces[i] * max(0.22, cooling)
                    let radius = positions[i].length
                    if radius > 9 { positions[i] = positions[i].normalized * 9 }
                }
            }
        }

        var links: [StarLayout.Link] = []
        var used = Set<String>()
        for i in entries.indices {
            let candidates = entries.indices.filter { $0 != i }.sorted { similarity[i][$0] > similarity[i][$1] }
            for j in candidates.prefix(2) where similarity[i][j] >= 0.28 {
                let a = min(i, j), b = max(i, j), key = "\(a):\(b)"
                if used.insert(key).inserted { links.append(.init(a: a, b: b, strength: similarity[i][j])) }
            }
        }
        let nodes = zip(entries, positions).map {
            StarLayout.Node(point: $0.0.point, position: SCNVector3($0.1.x, $0.1.y, $0.1.z))
        }
        return StarLayout(nodes: nodes, links: links)
    }

    private static func semanticVector(text: String, locale: String) -> [Double]? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let normalized = locale.replacingOccurrences(of: "_", with: "-").lowercased()
        let language: NLLanguage = normalized.hasPrefix("zh-hant") || normalized.hasPrefix("zh-tw")
            ? .traditionalChinese
            : normalized.hasPrefix("zh") ? .simplifiedChinese
            : normalized.hasPrefix("ja") ? .japanese
            : .english
        return NLEmbedding.sentenceEmbedding(for: language)?.vector(for: cleaned)
    }

    private static func cosine(_ lhs: [Double]?, _ rhs: [Double]?) -> Double? {
        guard let lhs, let rhs, lhs.count == rhs.count, !lhs.isEmpty else { return nil }
        var dot = 0.0, left = 0.0, right = 0.0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            left += lhs[index] * lhs[index]
            right += rhs[index] * rhs[index]
        }
        guard left > 0, right > 0 else { return nil }
        return dot / sqrt(left * right)
    }

    private static func lexicalSimilarity(_ lhs: String, _ rhs: String) -> Double {
        func grams(_ text: String) -> Set<String> {
            let characters = Array(text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation })
            guard characters.count > 1 else { return Set(characters.map(String.init)) }
            return Set((0..<(characters.count - 1)).map { String(characters[$0...($0 + 1)]) })
        }
        let left = grams(lhs), right = grams(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(left.union(right).count)
    }

    private static func initialPosition(id: PointID) -> Vector3 {
        let bytes = withUnsafeBytes(of: id.rawValue.uuid) { Array($0) }
        func unit(_ offset: Int) -> Float { Float((Int(bytes[offset]) << 8) | Int(bytes[offset + 1])) / 65_535 }
        let theta = unit(0) * .pi * 2
        let phi = acos(2 * unit(2) - 1)
        let radius: Float = 4.5
        return Vector3(x: radius * sin(phi) * cos(theta), y: radius * cos(phi), z: radius * sin(phi) * sin(theta))
    }
}
