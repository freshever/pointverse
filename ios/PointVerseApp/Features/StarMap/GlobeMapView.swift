import PointVerseKit
import SwiftUI

/// A system-UI globe: semantic positions are placed on a unit sphere and then
/// rendered with an orthographic projection. This avoids a GPU 3D engine while
/// preserving latitude, longitude, rotation and back-face occlusion.
struct GlobeMapView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var layout = StarLayout(nodes: [], links: [], embeddingCount: 0)
    @State private var selected: PointSummary?
    @State private var loadFailed = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.02, green: 0.08, blue: 0.16), .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            if layout.nodes.isEmpty {
                ContentUnavailableView {
                    Label("等待第一个坐标", systemImage: "globe.asia.australia.fill")
                } description: {
                    Text("保存想法后，它会出现在语义地球上。")
                }
                .foregroundStyle(.white)
            } else {
                SemanticGlobe(layout: layout) { selected = $0 }
            }
        }
        .navigationTitle("语义地球")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(Color(red: 0.02, green: 0.08, blue: 0.16), for: .navigationBar)
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
        .alert("无法读取语义地球", isPresented: $loadFailed) { Button("好") {} }
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

private struct SemanticGlobe: View {
    let layout: StarLayout
    let onSelect: (PointSummary) -> Void

    @State private var yaw: CGFloat = 0.35
    @State private var pitch: CGFloat = -0.18
    @State private var dragOrigin: CGPoint?
    @State private var rotationOrigin: CGPoint?
    @State private var zoom: CGFloat = 1
    @State private var zoomOrigin: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Canvas { context, size in
                    drawGlobe(context: &context, size: size)
                }
                .contentShape(Rectangle())
                .gesture(rotationGesture)
                .simultaneousGesture(magnificationGesture)
                .simultaneousGesture(
                    SpatialTapGesture().onEnded { value in
                        selectNode(at: value.location, size: proxy.size)
                    }
                )

                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Label("语义球面 · (layout.nodes.count) 个想法", systemImage: "network")
                                .font(.caption.bold())
                            Text("经纬度表示稳定的语义位置，不是现实地理位置")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.62))
                        }
                        Spacer()
                        Text("拖动旋转\n双指缩放")
                            .font(.caption2)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.white.opacity(0.62))
                    }
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 14))
                    .padding()

                    Spacer()

                    HStack(spacing: 12) {
                        controlButton("minus.magnifyingglass") { changeZoom(by: 0.8) }
                        Text("\(Int(zoom * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.75))
                            .frame(minWidth: 42)
                        controlButton("plus.magnifyingglass") { changeZoom(by: 1.25) }
                        Divider().frame(height: 24).overlay(.white.opacity(0.22))
                        Button("回到正面") {
                            withAnimation(.easeInOut(duration: 0.35)) {
                                yaw = 0.35
                                pitch = -0.18
                                zoom = 1
                            }
                        }
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.68), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.2)))
                    .padding(.bottom, 18)
                }
            }
        }
    }

    private var rotationGesture: some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                if dragOrigin == nil {
                    dragOrigin = value.startLocation
                    rotationOrigin = CGPoint(x: yaw, y: pitch)
                }
                guard let rotationOrigin else { return }
                yaw = rotationOrigin.x + value.translation.width * 0.009
                pitch = min(.pi / 2, max(-.pi / 2, rotationOrigin.y + value.translation.height * 0.009))
            }
            .onEnded { _ in
                dragOrigin = nil
                rotationOrigin = nil
            }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if zoomOrigin == nil { zoomOrigin = zoom }
                zoom = min(2.4, max(0.65, (zoomOrigin ?? zoom) * value))
            }
            .onEnded { _ in zoomOrigin = nil }
    }

    private func controlButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(.white.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
    }

    private func changeZoom(by factor: CGFloat) {
        withAnimation(.easeInOut(duration: 0.22)) {
            zoom = min(2.4, max(0.65, zoom * factor))
        }
    }

    private func drawGlobe(context: inout GraphicsContext, size: CGSize) {
        let geometry = globeGeometry(size: size)
        let globeRect = CGRect(
            x: geometry.center.x - geometry.radius,
            y: geometry.center.y - geometry.radius,
            width: geometry.radius * 2,
            height: geometry.radius * 2
        )

        context.fill(
            Path(ellipseIn: globeRect),
            with: .radialGradient(
                Gradient(colors: [Color.cyan.opacity(0.22), Color.blue.opacity(0.13), Color.black.opacity(0.88)]),
                center: CGPoint(x: geometry.center.x - geometry.radius * 0.28, y: geometry.center.y - geometry.radius * 0.3),
                startRadius: 2,
                endRadius: geometry.radius * 1.2
            )
        )
        context.stroke(Path(ellipseIn: globeRect), with: .color(.cyan.opacity(0.52)), lineWidth: 1.4)

        drawGraticule(context: &context, geometry: geometry)
        drawCoordinateLabels(context: &context, geometry: geometry)

        let projected = projectedNodes(geometry: geometry)
        for link in layout.links {
            let first = projected[link.a]
            let second = projected[link.b]
            guard first.visible, second.visible else { continue }
            var path = Path()
            path.move(to: first.point)
            path.addLine(to: second.point)
            context.stroke(
                path,
                with: .color(linkColor(link.strength).opacity(0.38)),
                style: StrokeStyle(lineWidth: 0.8 + max(0, link.strength - 0.85) * 8, dash: [4, 4])
            )
        }

        for node in projected.filter(\.visible).sorted(by: { $0.depth < $1.depth }) {
            let radius: CGFloat = node.embedded ? 6.5 : 5
            let color: Color = node.embedded ? .mint : .cyan
            let rect = CGRect(x: node.point.x - radius, y: node.point.y - radius, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: rect), with: .color(color))
            context.stroke(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)), with: .color(color.opacity(0.28)), lineWidth: 2)

            if zoom >= 1.15, !node.title.isEmpty {
                context.draw(
                    Text(String(node.title.prefix(10)))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.86)),
                    at: CGPoint(x: node.point.x, y: node.point.y + radius + 10),
                    anchor: .center
                )
            }
        }
    }

    private func drawGraticule(context: inout GraphicsContext, geometry: GlobeGeometry) {
        for latitude in stride(from: -60, through: 60, by: 30) {
            let samples = stride(from: -180, through: 180, by: 4).map {
                spherePoint(latitude: CGFloat(latitude), longitude: CGFloat($0))
            }
            strokeVisible(samples, context: &context, geometry: geometry, emphasized: latitude == 0)
        }
        for longitude in stride(from: -150, through: 180, by: 30) {
            let samples = stride(from: -90, through: 90, by: 3).map {
                spherePoint(latitude: CGFloat($0), longitude: CGFloat(longitude))
            }
            strokeVisible(samples, context: &context, geometry: geometry, emphasized: longitude == 0)
        }
    }

    private func drawCoordinateLabels(context: inout GraphicsContext, geometry: GlobeGeometry) {
        for latitude in stride(from: -60, through: 60, by: 30) {
            let rotated = rotate(spherePoint(latitude: CGFloat(latitude), longitude: 0))
            guard rotated.z >= 0 else { continue }
            let suffix = latitude == 0 ? "赤道" : "\(abs(latitude))°\(latitude > 0 ? "N" : "S")"
            context.draw(
                Text(suffix).font(.system(size: 8)).foregroundStyle(.white.opacity(0.46)),
                at: screenPoint(rotated, geometry: geometry),
                anchor: .leading
            )
        }
        for longitude in stride(from: -150, through: 150, by: 30) where longitude != 0 {
            let rotated = rotate(spherePoint(latitude: 0, longitude: CGFloat(longitude)))
            guard rotated.z >= 0 else { continue }
            let suffix = "\(abs(longitude))°\(longitude > 0 ? "E" : "W")"
            context.draw(
                Text(suffix).font(.system(size: 8)).foregroundStyle(.white.opacity(0.38)),
                at: screenPoint(rotated, geometry: geometry),
                anchor: .top
            )
        }
    }

    private func strokeVisible(
        _ samples: [Point3D],
        context: inout GraphicsContext,
        geometry: GlobeGeometry,
        emphasized: Bool
    ) {
        var path = Path()
        var drawing = false
        for sample in samples {
            let rotated = rotate(sample)
            let point = screenPoint(rotated, geometry: geometry)
            if rotated.z >= 0 {
                if drawing { path.addLine(to: point) } else { path.move(to: point); drawing = true }
            } else {
                drawing = false
            }
        }
        context.stroke(
            path,
            with: .color(.cyan.opacity(emphasized ? 0.32 : 0.16)),
            lineWidth: emphasized ? 1.1 : 0.65
        )
    }

    private func projectedNodes(geometry: GlobeGeometry) -> [GlobeNode] {
        layout.nodes.enumerated().map { index, node in
            let unit = node.position.normalized
            let rotated = rotate(unit)
            return GlobeNode(
                index: index,
                point: screenPoint(rotated, geometry: geometry),
                depth: rotated.z,
                visible: rotated.z >= 0,
                title: node.point.title,
                embedded: node.isEmbedded
            )
        }
    }

    private func selectNode(at location: CGPoint, size: CGSize) {
        let nodes = projectedNodes(geometry: globeGeometry(size: size)).filter(\.visible)
        guard let nearest = nodes.min(by: {
            hypot($0.point.x - location.x, $0.point.y - location.y) < hypot($1.point.x - location.x, $1.point.y - location.y)
        }), hypot(nearest.point.x - location.x, nearest.point.y - location.y) <= 26 else { return }
        onSelect(layout.nodes[nearest.index].point)
    }

    private func globeGeometry(size: CGSize) -> GlobeGeometry {
        let availableHeight = max(160, size.height - 145)
        return GlobeGeometry(
            center: CGPoint(x: size.width / 2, y: size.height / 2 + 5),
            radius: min(size.width * 0.43, availableHeight * 0.44) * zoom
        )
    }

    private func rotate(_ point: Point3D) -> Point3D {
        let cosY = cos(yaw), sinY = sin(yaw)
        let x1 = point.x * cosY + point.z * sinY
        let z1 = -point.x * sinY + point.z * cosY
        let cosX = cos(pitch), sinX = sin(pitch)
        return Point3D(
            x: x1,
            y: point.y * cosX - z1 * sinX,
            z: point.y * sinX + z1 * cosX
        )
    }

    private func screenPoint(_ point: Point3D, geometry: GlobeGeometry) -> CGPoint {
        CGPoint(
            x: geometry.center.x + point.x * geometry.radius,
            y: geometry.center.y - point.y * geometry.radius
        )
    }

    private func spherePoint(latitude: CGFloat, longitude: CGFloat) -> Point3D {
        let lat = latitude * .pi / 180
        let lon = longitude * .pi / 180
        return Point3D(x: cos(lat) * sin(lon), y: sin(lat), z: cos(lat) * cos(lon))
    }

    private func linkColor(_ score: CGFloat) -> Color {
        score >= 0.94 ? .mint : score >= 0.89 ? .cyan : .indigo
    }
}

private struct GlobeGeometry {
    let center: CGPoint
    let radius: CGFloat
}

private struct GlobeNode {
    let index: Int
    let point: CGPoint
    let depth: CGFloat
    let visible: Bool
    let title: String
    let embedded: Bool
}
