import PointVerseKit
import SwiftUI

/// A system-UI globe: semantic positions are placed on a unit sphere and then
/// rendered with an orthographic projection. This avoids a GPU 3D engine while
/// preserving latitude, longitude, rotation and back-face occlusion.
struct GlobeMapView: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.appLanguage) private var appLanguage
    @State private var layout = StarLayout(nodes: [], links: [], embeddingCount: 0)
    @State private var geographies: [PointID: PointGeographyRecord] = [:]
    @State private var contentByPointID: [PointID: String] = [:]
    @State private var selected: PointSummary?
    @State private var loadFailed = false
    @State private var showingDemo = false
    @State private var isRecalculating = false
    @State private var pendingSemanticCount = 0

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
                    if let error = container.embeddingStartupError {
                        Text(error)
                    } else {
                        Text(pendingSemanticCount > 0
                             ? "\(pendingSemanticCount) 条内容正在等待转写或语义分析。"
                             : AppLocalization.string("保存想法后，它会出现在语义星球上。", language: appLanguage))
                    }
                }
                .foregroundStyle(.white)
            } else {
                SemanticGlobe(layout: layout, geographies: geographies, contentByPointID: contentByPointID) { selected = $0 }
            }
        }
        .navigationTitle(AppLocalization.string("语义星球", language: appLanguage))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(Color(red: 0.02, green: 0.08, blue: 0.16), for: .navigationBar)
        .toolbar {
            Button { showingDemo = true } label: { Image(systemName: "flask") }
                .tint(.white)
                .accessibilityLabel("打开球面分布演示")
            Button {
                Task { await recalculateGeography() }
            } label: {
                if isRecalculating {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "location.circle")
                }
            }
            .tint(.white)
            .disabled(isRecalculating)
            .accessibilityLabel("重新计算经纬度")
            Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                .tint(.white)
        }
        .task {
            container.refreshEmbeddings()
            await reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: EmbeddingService.didChangeNotification)) { _ in
            Task { await reload() }
        }
        .sheet(item: $selected) { point in
            NavigationStack { PointDetailView(point: point) }
                .environmentObject(container)
                .presentationDetents([.medium, .large])
        }
        .alert(AppLocalization.string("无法读取语义星球", language: appLanguage), isPresented: $loadFailed) {
            Button(AppLocalization.string("好", language: appLanguage)) {}
        }
        .sheet(isPresented: $showingDemo) {
            NavigationStack { PlanetDistributionDemoView() }
        }
    }

    private func reload() async {
        await loadGeography(discardingSavedCoordinates: false)
    }

    private func recalculateGeography() async {
        guard !isRecalculating else { return }
        isRecalculating = true
        await loadGeography(discardingSavedCoordinates: true)
        isRecalculating = false
    }

    private func loadGeography(discardingSavedCoordinates: Bool) async {
        do {
            async let entries = container.database.pointMapEntries()
            async let embeddings = container.database.embeddings(modelID: EmbeddingModelIdentity.bgeSmallZhV15)
            async let storedGeographies = container.database.geographies(version: GeographyIdentity.relativeSemanticV6)
            let loadedEntries = try await entries
            let loadedEmbeddings = try await embeddings
            let embeddedPointIDs = Set(loadedEmbeddings.map(\.pointID))
            // A point must not receive a fake geography based on its ID or its
            // voice modality. It joins the globe only after its transcribed
            // text (plus understood image text) has a real E5 embedding.
            let semanticEntries = loadedEntries.filter { embeddedPointIDs.contains($0.id) }
            pendingSemanticCount = loadedEntries.count - semanticEntries.count
            let previous = discardingSavedCoordinates ? [] : try await storedGeographies
            let generated = SemanticGeographyEngine.make(embeddings: loadedEmbeddings, previous: previous)
            PointVerseLog.embedding.info("Globe reload entries=\(loadedEntries.count, privacy: .public) embeddings=\(loadedEmbeddings.count, privacy: .public) pending=\(pendingSemanticCount, privacy: .public) communities=\(Set(generated.compactMap(\.communityID)).count, privacy: .public)")
            try await container.database.saveGeographies(generated)
            layout = StarLayoutEngine.make(entries: semanticEntries, embeddings: loadedEmbeddings)
            geographies = Dictionary(uniqueKeysWithValues: generated.map { ($0.pointID, $0) })
            contentByPointID = Dictionary(uniqueKeysWithValues: semanticEntries.map { ($0.id, $0.content) })
        } catch {
            loadFailed = true
        }
    }
}

private struct SemanticGlobe: View {
    private let minimumZoom: CGFloat = 0.325
    private let maximumZoom: CGFloat = 24
    let layout: StarLayout
    let onSelect: (PointSummary) -> Void
    private let topicByPointID: [PointID: String]
    private let communityByPointID: [PointID: String]
    private let contentByPointID: [PointID: String]
    private let spherePositions: [Point3D]

    @State private var orientation = Rotation3D.camera(yaw: 0.35, pitch: -0.18)
    @State private var dragOrigin: CGPoint?
    @State private var rotationOrigin: Rotation3D?
    @State private var zoom: CGFloat = 1
    @State private var zoomOrigin: CGFloat?
    @State private var showingRegions = false
    @State private var showsGeography = true
    @State private var cachedAdministrativeLabels: [AdministrativeLabel] = []
    @State private var placeNameOverrides: [String: String]

    init(
        layout: StarLayout,
        geographies: [PointID: PointGeographyRecord],
        contentByPointID: [PointID: String] = [:],
        topicByPointID: [PointID: String] = [:],
        initialYaw: CGFloat = 0.35,
        initialZoom: CGFloat = 1,
        onSelect: @escaping (PointSummary) -> Void
    ) {
        self.layout = layout
        self.onSelect = onSelect
        self.topicByPointID = topicByPointID
        self.communityByPointID = geographies.compactMapValues(\.communityID)
        self.contentByPointID = contentByPointID
        _orientation = State(initialValue: .camera(yaw: initialYaw, pitch: -0.18))
        _zoom = State(initialValue: initialZoom)
        _placeNameOverrides = State(initialValue: Self.loadPlaceNameOverrides())
        self.spherePositions = layout.nodes.map { node in
            guard let geography = geographies[node.point.id] else { return Self.compactFallback(id: node.point.id) }
            let latitude = CGFloat(geography.latitude) * .pi / 180
            let longitude = CGFloat(geography.longitude) * .pi / 180
            return Point3D(
                x: cos(latitude) * sin(longitude),
                y: sin(latitude),
                z: cos(latitude) * cos(longitude)
            )
        }
    }

    private static func compactFallback(id: PointID) -> Point3D {
        let bytes = withUnsafeBytes(of: id.rawValue.uuid) { Array($0) }
        let radial = CGFloat((Int(bytes[0]) << 8) | Int(bytes[1])) / 65_535
        let bearing = CGFloat((Int(bytes[2]) << 8) | Int(bytes[3])) / 65_535 * 2 * .pi
        let angle = sqrt(radial) * 0.18
        return Point3D(x: sin(angle) * cos(bearing), y: sin(angle) * sin(bearing), z: cos(angle))
    }

    private var regions: [CommunityRegion] {
        let keys = layout.nodes.map { node -> String? in
            if let community = communityByPointID[node.point.id] { return community }
            return topicByPointID[node.point.id].map { "demo:\($0)" }
        }
        let groups = Dictionary(grouping: layout.nodes.indices.compactMap { index -> (String, Int)? in
            guard let key = keys[index] else { return nil }
            return (key, index)
        }, by: \.0)
        return groups.map { key, entries in
            let indices = entries.map(\.1)
            let center = indices.reduce(Point3D(x: 0, y: 0, z: 0)) { $0 + spherePositions[$1] }.normalized
            let representative = indices.min {
                sphericalAngle(spherePositions[$0], center) < sphericalAngle(spherePositions[$1], center)
            }!
            let title = key.hasPrefix("demo:")
                ? String(key.dropFirst(5))
                : String(layout.nodes[representative].point.title.prefix(12))
            return CommunityRegion(
                id: key,
                title: title.isEmpty ? "未命名区域" : title,
                isDemoTopic: key.hasPrefix("demo:"),
                members: indices.map { index in
                    let point = layout.nodes[index].point
                    return CommunityMember(point: point, content: contentByPointID[point.id] ?? "")
                }.sorted { $0.point.createdAt > $1.point.createdAt },
                center: center
            )
        }.sorted { $0.members.count == $1.members.count ? $0.id < $1.id : $0.members.count > $1.members.count }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Canvas { context, size in
                    drawGlobe(context: &context, size: size)
                }
                .contentShape(Rectangle())
                .gesture(rotationGesture(size: proxy.size))
                .simultaneousGesture(magnificationGesture)
                .simultaneousGesture(
                    SpatialTapGesture().onEnded { value in
                        selectNode(at: value.location, size: proxy.size)
                    }
                )

                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Label("语义球面 · \(layout.nodes.count) 个想法", systemImage: "network")
                                .font(.caption.bold())
                            Text("经纬度表示稳定的语义位置，不是现实地理位置")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.62))
                        }
                        Spacer()
                        Text("拖动地图\n双指缩放")
                            .font(.caption2)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.white.opacity(0.62))
                    }
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 14))
                    .padding()

                    HStack(spacing: 14) {
                        Label("北极 · 抽象 / 原理 / 长期", systemImage: "arrow.up.circle.fill")
                            .foregroundStyle(.cyan)
                        Spacer(minLength: 0)
                        Label("南极 · 具体 / 行动 / 当下", systemImage: "arrow.down.circle.fill")
                            .foregroundStyle(.orange)
                    }
                    .font(.caption2)
                    .padding(.horizontal, 18)
                    Text("语义轴尚未校准；当前 Point 纬度不代表抽象或行动分数")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.top, 4)

                    if !communityByPointID.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "circle.hexagongrid.fill")
                                .foregroundStyle(.mint)
                            Text("\(layout.embeddingCount) 条有效向量 · \(Set(communityByPointID.values).count) 个语义群")
                            Spacer()
                            Circle().fill(.gray).frame(width: 7, height: 7)
                            Text("待分析")
                        }
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 18)
                        .padding(.top, 6)
                    }

                    Button {
                        showingRegions = true
                    } label: {
                        Label("查看分区主题与成员", systemImage: "square.grid.2x2")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.black.opacity(0.62), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showsGeography.toggle()
                        }
                    } label: {
                        Label(
                            showsGeography ? "隐藏地理层" : "显示地理层",
                            systemImage: showsGeography ? "map.fill" : "map"
                        )
                        .font(.caption.bold())
                        .foregroundStyle(showsGeography ? .cyan : .white.opacity(0.72))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.black.opacity(0.62), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)

                    Spacer()

                    HStack(spacing: 12) {
                        controlButton("minus.magnifyingglass") { changeZoom(by: 0.625) }
                        Text("\(Int(zoom * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.75))
                            .frame(minWidth: 42)
                        controlButton("plus.magnifyingglass") { changeZoom(by: 1.6) }
                        Divider().frame(height: 24).overlay(.white.opacity(0.22))
                        Button("回到正面") {
                            withAnimation(.easeInOut(duration: 0.35)) {
                                orientation = .camera(yaw: 0.35, pitch: -0.18)
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
        .sheet(isPresented: $showingRegions) {
            NavigationStack {
                List {
                    Section("知识地图") {
                        NavigationLink {
                            PlaceNamesEditorView(
                                labels: cachedAdministrativeLabels,
                                overrides: $placeNameOverrides
                            )
                        } label: {
                            Label("修改省市区名称", systemImage: "pencil.and.list.clipboard")
                        }
                    }
                    Section("语义分区与内容") {
                        ForEach(regions) { region in
                            NavigationLink {
                                List(region.members) { point in
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(point.point.title.isEmpty ? "未命名 Point" : point.point.title)
                                            .font(.body.bold())
                                        if !point.content.isEmpty {
                                            Text(point.content)
                                                .font(.subheadline)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(4)
                                        }
                                    }
                                }
                                .navigationTitle(displayName(for: "province:\(region.id)") ?? region.title)
                            } label: {
                                HStack(spacing: 10) {
                                    Circle()
                                        .fill(regionColor(region))
                                        .frame(width: 12, height: 12)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(displayName(for: "province:\(region.id)") ?? region.title)
                                            .lineLimit(1)
                                        Text("根据区域内容生成，可在地名管理中修改")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text("\(region.members.count)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .navigationTitle("语义分区")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    Button("完成") { showingRegions = false }
                }
            }
        }
        .onAppear {
            if cachedAdministrativeLabels.isEmpty {
                cachedAdministrativeLabels = makeAdministrativeLabels()
            }
        }
        .onChange(of: layout.nodes.count) { _, _ in
            cachedAdministrativeLabels = makeAdministrativeLabels()
        }
        .onChange(of: placeNameOverrides) { _, overrides in
            Self.savePlaceNameOverrides(overrides)
        }
    }

    private func regionColor(_ region: CommunityRegion) -> Color {
        region.isDemoTopic ? Self.topicColor(region.title) : Self.communityColor(region.id)
    }

    private func displayName(for id: String) -> String? {
        guard let label = cachedAdministrativeLabels.first(where: { $0.id == id }) else { return nil }
        return placeNameOverrides[id].flatMap { $0.isEmpty ? nil : $0 } ?? label.defaultName
    }

    private func rotationGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                if dragOrigin == nil {
                    dragOrigin = value.startLocation
                    rotationOrigin = orientation
                }
                guard let rotationOrigin else { return }
                // Map-style 1:1 panning: a drag is converted through the
                // current projected radius. At high zoom the same finger
                // distance therefore moves a much smaller geographic angle.
                let radius = max(80, globeGeometry(size: size).radius)
                let horizontal = Rotation3D.rotationY(value.translation.width / radius)
                let vertical = Rotation3D.rotationX(value.translation.height / radius)
                orientation = vertical * horizontal * rotationOrigin
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
                zoom = min(maximumZoom, max(minimumZoom, (zoomOrigin ?? zoom) * value))
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
            zoom = min(maximumZoom, max(minimumZoom, zoom * factor))
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

        if showsGeography {
            drawSemanticLand(context: &context, geometry: geometry)
        }
        drawGraticule(context: &context, geometry: geometry)
        drawCoordinateLabels(context: &context, geometry: geometry)
        drawPoleLabels(context: &context, geometry: geometry)

        let projected = projectedNodes(geometry: geometry)
        let clusters = displayClusters(projected: projected, geometry: geometry)

        for cluster in clusters.sorted(by: { $0.depth < $1.depth }) {
            if cluster.nodeIndices.count > 1 {
                let radius = min(25, 11 + sqrt(CGFloat(cluster.nodeIndices.count)) * 3.5)
                let rect = CGRect(x: cluster.point.x - radius, y: cluster.point.y - radius, width: radius * 2, height: radius * 2)
                let communityIDs = Set(cluster.nodeIndices.compactMap { projected[$0].communityID })
                let clusterColor = communityIDs.count == 1
                    ? Self.communityColor(communityIDs.first!) : Color.indigo
                context.fill(
                    Path(ellipseIn: rect),
                    with: .radialGradient(
                        Gradient(colors: [clusterColor.opacity(0.95), clusterColor.opacity(0.72), .blue.opacity(0.65)]),
                        center: cluster.point,
                        startRadius: 1,
                        endRadius: radius
                    )
                )
                context.stroke(Path(ellipseIn: rect.insetBy(dx: -4, dy: -4)), with: .color(.cyan.opacity(0.3)), lineWidth: 2)
                context.draw(
                    Text("\(cluster.nodeIndices.count)").font(.system(size: 24, weight: .bold)).foregroundStyle(.white),
                    at: cluster.point,
                    anchor: .center
                )
                continue
            }
            guard let nodeIndex = cluster.nodeIndices.first else { continue }
            let node = projected[nodeIndex]
            let radius: CGFloat = node.embedded ? 6.5 : 5
            let color: Color = node.communityID.map(Self.communityColor)
                ?? node.topic.map(Self.topicColor)
                ?? (node.embedded ? .mint : .gray)
            let rect = CGRect(x: node.point.x - radius, y: node.point.y - radius, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: rect), with: .color(color))
            context.stroke(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)), with: .color(color.opacity(0.28)), lineWidth: 2)

            if zoom >= 10, !node.title.isEmpty {
                let characterLimit = zoom >= 18 ? 56 : 28
                let content = String(node.title.prefix(characterLimit))
                let lines = max(1, min(3, Int(ceil(Double(content.count) / 14.0))))
                let bubbleWidth: CGFloat = zoom >= 18 ? 190 : 150
                let bubbleHeight = CGFloat(lines * 19 + 12)
                let bubble = CGRect(
                    x: node.point.x - bubbleWidth / 2,
                    y: node.point.y + radius + 7,
                    width: bubbleWidth,
                    height: bubbleHeight
                )
                context.fill(Path(roundedRect: bubble, cornerRadius: 8), with: .color(.black.opacity(0.78)))
                context.stroke(Path(roundedRect: bubble, cornerRadius: 8), with: .color(color.opacity(0.55)), lineWidth: 1)
                context.draw(
                    Text(content)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white.opacity(0.86)),
                    in: bubble.insetBy(dx: 6, dy: 5)
                )
            }
        }

        drawAdministrativeLabels(context: &context, geometry: geometry)
    }

    private func drawAdministrativeLabels(context: inout GraphicsContext, geometry: GlobeGeometry) {
        let visibleLevel: AdministrativeLevel
        switch zoom {
        case ..<1.8: visibleLevel = .province
        case ..<5: visibleLevel = .city
        default: visibleLevel = .district
        }
        let labels = cachedAdministrativeLabels.filter { $0.level == visibleLevel }
        for label in labels {
            let rotated = rotate(label.center)
            guard rotated.z >= 0 else { continue }
            let center = screenPoint(rotated, geometry: geometry)
            let fontSize: CGFloat = visibleLevel == .province ? 14 : visibleLevel == .city ? 13 : 12
            let name = placeNameOverrides[label.id].flatMap { $0.isEmpty ? nil : $0 } ?? label.defaultName
            let shown = String(name.prefix(visibleLevel == .province ? 12 : 9))
            let width = min(180, CGFloat(shown.count) * fontSize + 22)
            let rect = CGRect(x: center.x - width / 2, y: center.y - 16, width: width, height: 27)
            context.fill(Path(roundedRect: rect, cornerRadius: 7), with: .color(.black.opacity(0.8)))
            context.stroke(Path(roundedRect: rect, cornerRadius: 7), with: .color(label.color.opacity(0.85)), lineWidth: visibleLevel == .province ? 1.5 : 1)
            context.draw(
                Text(shown).font(.system(size: fontSize, weight: .semibold)).foregroundStyle(.white),
                at: CGPoint(x: rect.midX, y: rect.midY),
                anchor: .center
            )
        }
    }

    private func makeAdministrativeLabels() -> [AdministrativeLabel] {
        let indexByID = Dictionary(uniqueKeysWithValues: layout.nodes.indices.map { (layout.nodes[$0].point.id, $0) })
        var labels: [AdministrativeLabel] = []
        for region in regions {
            let indices = region.members.compactMap { indexByID[$0.point.id] }
            guard !indices.isEmpty else { continue }
            let color = regionColor(region)
            let provinceName = "\(semanticPlaceName(indices, level: .province))省"
            let provinceID = "province:\(region.id)"
            labels.append(.init(id: provinceID, level: .province, defaultName: provinceName, center: region.center, color: color))

            for (cityIndex, cityIndices) in geographicPartitions(indices, bucketCount: 6, around: region.center) {
                let cityCenter = meanPosition(cityIndices)
                let cityName = "\(semanticPlaceName(cityIndices, level: .city))市"
                let cityID = "\(provinceID)/city:\(cityIndex)"
                labels.append(.init(id: cityID, level: .city, defaultName: cityName, center: cityCenter, color: color))

                for (districtIndex, districtIndices) in geographicPartitions(cityIndices, bucketCount: 24, around: region.center) {
                    let districtCenter = meanPosition(districtIndices)
                    let districtName = "\(semanticPlaceName(districtIndices, level: .district))区"
                    labels.append(.init(
                        id: "\(cityID)/district:\(districtIndex)",
                        level: .district,
                        defaultName: districtName,
                        center: districtCenter,
                        color: color
                    ))
                }
            }
        }
        return labels
    }

    private func geographicPartitions(_ indices: [Int], bucketCount: Int, around center: Point3D) -> [(Int, [Int])] {
        guard bucketCount > 1 else { return [(0, indices)] }
        let east = Point3D(x: -center.z, y: 0, z: center.x).normalized
        let north = Point3D(
            x: center.y * east.z,
            y: center.z * east.x - center.x * east.z,
            z: -center.y * east.x
        ).normalized
        let grouped = Dictionary(grouping: indices) { index -> Int in
            let bearing = localBearing(spherePositions[index], east: east, north: north)
            let normalized = (bearing + .pi) / (2 * .pi)
            return min(bucketCount - 1, max(0, Int(floor(normalized * CGFloat(bucketCount)))))
        }
        return grouped.keys.sorted().compactMap { bucket in
            grouped[bucket].map { (bucket, $0) }
        }
    }

    private func localBearing(_ point: Point3D, east: Point3D, north: Point3D) -> CGFloat {
        atan2(point.x * east.x + point.y * east.y + point.z * east.z,
              point.x * north.x + point.y * north.y + point.z * north.z)
    }

    private func meanPosition(_ indices: [Int]) -> Point3D {
        indices.reduce(Point3D(x: 0, y: 0, z: 0)) { $0 + spherePositions[$1] }.normalized
    }

    private func semanticPlaceName(_ indices: [Int], level: AdministrativeLevel) -> String {
        let contents = indices.map { index in
            let point = layout.nodes[index].point
            return contentByPointID[point.id].flatMap { $0.isEmpty ? nil : $0 } ?? point.title
        }
        return SemanticPlaceNameEngine.name(contents: contents, level: level)
    }

    private static let placeNameOverridesKey = "semanticGeography.placeNameOverrides.v1"

    private static func loadPlaceNameOverrides() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: placeNameOverridesKey),
              let value = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return value
    }

    private static func savePlaceNameOverrides(_ value: [String: String]) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: placeNameOverridesKey)
    }

    /// Paints a stable semantic atlas. Ownership is resolved on the unrotated
    /// sphere, so camera rotation cannot move borders or change a cell's region.
    /// Cells too far from every Point remain ocean instead of inventing land.
    private func drawSemanticLand(context: inout GraphicsContext, geometry: GlobeGeometry) {
        let positionByPointID = Dictionary(uniqueKeysWithValues: layout.nodes.indices.map {
            (layout.nodes[$0].point.id, spherePositions[$0])
        })
        let atlasRegions = regions.map { region in
            let memberPositions = region.members.compactMap { positionByPointID[$0.point.id] }
            let contentRadius = memberPositions.map { sphericalAngle(region.center, $0) }.max() ?? 0
            return SemanticAtlasRegion(
                id: region.id,
                center: region.center,
                color: regionColor(region),
                landRadius: min(0.72, max(0.34, contentRadius + 0.20))
            )
        }
        guard !atlasRegions.isEmpty else { return }
        let step: CGFloat = 6

        func owner(at point: Point3D) -> SemanticAtlasRegion? {
            guard let nearest = atlasRegions.min(by: {
                sphericalAngle($0.center, point) < sphericalAngle($1.center, point)
            }) else { return nil }
            return sphericalAngle(nearest.center, point) <= nearest.landRadius ? nearest : nil
        }

        for latitude in stride(from: CGFloat(-84), to: CGFloat(84), by: step) {
            for longitude in stride(from: CGFloat(-180), to: CGFloat(180), by: step) {
                let middle = spherePoint(latitude: latitude + step / 2, longitude: longitude + step / 2)
                guard let region = owner(at: middle) else { continue }
                let corners = [
                    spherePoint(latitude: latitude, longitude: longitude),
                    spherePoint(latitude: latitude, longitude: longitude + step),
                    spherePoint(latitude: latitude + step, longitude: longitude + step),
                    spherePoint(latitude: latitude + step, longitude: longitude)
                ].map(rotate)
                guard corners.allSatisfy({ $0.z >= 0 }) else { continue }
                var cell = Path()
                cell.move(to: screenPoint(corners[0], geometry: geometry))
                for corner in corners.dropFirst() { cell.addLine(to: screenPoint(corner, geometry: geometry)) }
                cell.closeSubpath()
                context.fill(cell, with: .color(region.color.opacity(0.24)))

                // A coast borders ocean; an administrative border separates owners.
                let east = owner(at: spherePoint(latitude: latitude + step / 2, longitude: longitude + step * 1.5))
                let north = owner(at: spherePoint(latitude: latitude + step * 1.5, longitude: longitude + step / 2))
                if east?.id != region.id {
                    strokeAtlasEdge(corners[1], corners[2], isCoast: east == nil, region: region, context: &context, geometry: geometry)
                }
                if north?.id != region.id {
                    strokeAtlasEdge(corners[2], corners[3], isCoast: north == nil, region: region, context: &context, geometry: geometry)
                }
            }
        }
    }

    private func strokeAtlasEdge(
        _ start: Point3D,
        _ end: Point3D,
        isCoast: Bool,
        region: SemanticAtlasRegion,
        context: inout GraphicsContext,
        geometry: GlobeGeometry
    ) {
        var edge = Path()
        edge.move(to: screenPoint(start, geometry: geometry))
        edge.addLine(to: screenPoint(end, geometry: geometry))
        context.stroke(
            edge,
            with: .color((isCoast ? Color.cyan : region.color).opacity(isCoast ? 0.4 : 0.66)),
            style: StrokeStyle(lineWidth: isCoast ? 0.8 : 1.1)
        )
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
                Text(suffix).font(.system(size: 16)).foregroundStyle(.white.opacity(0.46)),
                at: screenPoint(rotated, geometry: geometry),
                anchor: .leading
            )
        }
        for longitude in stride(from: -150, through: 150, by: 30) where longitude != 0 {
            let rotated = rotate(spherePoint(latitude: 0, longitude: CGFloat(longitude)))
            guard rotated.z >= 0 else { continue }
            let suffix = "\(abs(longitude))°\(longitude > 0 ? "E" : "W")"
            context.draw(
                Text(suffix).font(.system(size: 16)).foregroundStyle(.white.opacity(0.38)),
                at: screenPoint(rotated, geometry: geometry),
                anchor: .top
            )
        }
    }

    private func drawPoleLabels(context: inout GraphicsContext, geometry: GlobeGeometry) {
        for (pole, title, color) in [
            (Point3D(x: 0, y: 1, z: 0), "北极 · 抽象 / 原理 / 长期", Color.cyan),
            (Point3D(x: 0, y: -1, z: 0), "南极 · 具体 / 行动 / 当下", Color.orange)
        ] {
            let rotated = rotate(pole)
            guard rotated.z >= -0.001 else { continue }
            let location = screenPoint(rotated, geometry: geometry)
            context.fill(Path(ellipseIn: CGRect(x: location.x - 4, y: location.y - 4, width: 8, height: 8)), with: .color(color))
            context.draw(
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(color),
                at: CGPoint(x: location.x, y: location.y + (pole.y > 0 ? -14 : 14)),
                anchor: pole.y > 0 ? .bottom : .top
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
            let unit = spherePositions[index]
            let rotated = rotate(unit)
            return GlobeNode(
                index: index,
                point: screenPoint(rotated, geometry: geometry),
                depth: rotated.z,
                visible: rotated.z >= 0,
                title: contentByPointID[node.point.id].flatMap { $0.isEmpty ? nil : $0 } ?? node.point.title,
                embedded: node.isEmbedded,
                topic: topicByPointID[node.point.id],
                communityID: communityByPointID[node.point.id]
            )
        }
    }

    private func selectNode(at location: CGPoint, size: CGSize) {
        let projected = projectedNodes(geometry: globeGeometry(size: size))
        let clusters = displayClusters(projected: projected, geometry: globeGeometry(size: size))
        guard let nearest = clusters.min(by: {
            hypot($0.point.x - location.x, $0.point.y - location.y) < hypot($1.point.x - location.x, $1.point.y - location.y)
        }), hypot(nearest.point.x - location.x, nearest.point.y - location.y) <= 26 else { return }
        if nearest.nodeIndices.count > 1 {
            withAnimation(.easeInOut(duration: 0.28)) {
                zoom = min(maximumZoom, max(1.12, zoom * 1.5))
            }
        } else if let index = nearest.nodeIndices.first {
            onSelect(layout.nodes[index].point)
        }
    }

    /// Map-style clustering in spherical coordinates. Membership is calculated
    /// before camera rotation, so dragging the globe never changes a cluster.
    /// Zoom is the only input that controls when a cluster expands into leaves.
    private func displayClusters(projected: [GlobeNode], geometry: GlobeGeometry) -> [GlobeCluster] {
        guard zoom < 1.75 else {
            return projected.filter(\.visible).map {
                GlobeCluster(id: $0.index, nodeIndices: [$0.index], point: $0.point, depth: $0.depth)
            }
        }

        let angularDistance: CGFloat
        switch zoom {
        case ..<0.82: angularDistance = 0.17
        case ..<1.08: angularDistance = 0.12
        case ..<1.38: angularDistance = 0.08
        default: angularDistance = 0.045
        }
        var remaining = Set(layout.nodes.indices)
        var result: [GlobeCluster] = []

        while let seed = remaining.min() {
            remaining.remove(seed)
            let seedPosition = spherePositions[seed]
            let neighbors = remaining.filter { candidate in
                sphericalAngle(seedPosition, spherePositions[candidate]) <= angularDistance
            }
            let members = [seed] + neighbors.sorted()
            remaining.subtract(neighbors)

            let center = members.reduce(Point3D(x: 0, y: 0, z: 0)) {
                $0 + spherePositions[$1]
            }.normalized
            let rotatedCenter = rotate(center)
            guard rotatedCenter.z >= 0 else { continue }
            result.append(
                GlobeCluster(
                    id: seed,
                    nodeIndices: members,
                    point: screenPoint(rotatedCenter, geometry: geometry),
                    depth: rotatedCenter.z
                )
            )
        }
        return result
    }

    private func sphericalAngle(_ lhs: Point3D, _ rhs: Point3D) -> CGFloat {
        let dot = min(1, max(-1, lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z))
        return acos(dot)
    }

    private func globeGeometry(size: CGSize) -> GlobeGeometry {
        let availableHeight = max(160, size.height - 145)
        return GlobeGeometry(
            center: CGPoint(x: size.width / 2, y: size.height / 2 + 5),
            radius: min(size.width * 0.43, availableHeight * 0.44) * zoom
        )
    }

    private func rotate(_ point: Point3D) -> Point3D {
        orientation.applying(to: point)
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

    private static func topicColor(_ topic: String) -> Color {
        let topics = ["哲学", "编程", "烹饪", "天文", "园艺", "音乐", "金融", "运动", "历史", "医疗", "旅行", "文学"]
        let palette: [Color] = [.purple, .cyan, .orange, .blue, .green, .pink, .yellow, .mint, .brown, .red, .teal, .indigo]
        guard let index = topics.firstIndex(of: topic) else { return .white }
        return palette[index]
    }

    private static func communityColor(_ communityID: String) -> Color {
        // Swift's Hasher is randomized per process; FNV keeps colors stable
        // across launches without assigning meaning to the UUID itself.
        let hash = communityID.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.82, brightness: 0.95)
    }
}

private struct GlobeGeometry {
    let center: CGPoint
    let radius: CGFloat
}

/// Camera-space globe orientation. Incremental rotations are composed around
/// the screen's X/Y axes, avoiding the yaw/pitch singularity at either pole.
private struct Rotation3D {
    let m11: CGFloat, m12: CGFloat, m13: CGFloat
    let m21: CGFloat, m22: CGFloat, m23: CGFloat
    let m31: CGFloat, m32: CGFloat, m33: CGFloat

    static let identity = Rotation3D(
        m11: 1, m12: 0, m13: 0,
        m21: 0, m22: 1, m23: 0,
        m31: 0, m32: 0, m33: 1
    )

    static func camera(yaw: CGFloat, pitch: CGFloat) -> Self {
        rotationX(pitch) * rotationY(yaw)
    }

    static func rotationX(_ angle: CGFloat) -> Self {
        let cosine = cos(angle), sine = sin(angle)
        return .init(
            m11: 1, m12: 0, m13: 0,
            m21: 0, m22: cosine, m23: -sine,
            m31: 0, m32: sine, m33: cosine
        )
    }

    static func rotationY(_ angle: CGFloat) -> Self {
        let cosine = cos(angle), sine = sin(angle)
        return .init(
            m11: cosine, m12: 0, m13: sine,
            m21: 0, m22: 1, m23: 0,
            m31: -sine, m32: 0, m33: cosine
        )
    }

    static func * (lhs: Self, rhs: Self) -> Self {
        .init(
            m11: lhs.m11 * rhs.m11 + lhs.m12 * rhs.m21 + lhs.m13 * rhs.m31,
            m12: lhs.m11 * rhs.m12 + lhs.m12 * rhs.m22 + lhs.m13 * rhs.m32,
            m13: lhs.m11 * rhs.m13 + lhs.m12 * rhs.m23 + lhs.m13 * rhs.m33,
            m21: lhs.m21 * rhs.m11 + lhs.m22 * rhs.m21 + lhs.m23 * rhs.m31,
            m22: lhs.m21 * rhs.m12 + lhs.m22 * rhs.m22 + lhs.m23 * rhs.m32,
            m23: lhs.m21 * rhs.m13 + lhs.m22 * rhs.m23 + lhs.m23 * rhs.m33,
            m31: lhs.m31 * rhs.m11 + lhs.m32 * rhs.m21 + lhs.m33 * rhs.m31,
            m32: lhs.m31 * rhs.m12 + lhs.m32 * rhs.m22 + lhs.m33 * rhs.m32,
            m33: lhs.m31 * rhs.m13 + lhs.m32 * rhs.m23 + lhs.m33 * rhs.m33
        )
    }

    func applying(to point: Point3D) -> Point3D {
        Point3D(
            x: m11 * point.x + m12 * point.y + m13 * point.z,
            y: m21 * point.x + m22 * point.y + m23 * point.z,
            z: m31 * point.x + m32 * point.y + m33 * point.z
        )
    }
}

private struct GlobeNode {
    let index: Int
    let point: CGPoint
    let depth: CGFloat
    let visible: Bool
    let title: String
    let embedded: Bool
    let topic: String?
    let communityID: String?
}

private struct GlobeCluster {
    let id: Int
    let nodeIndices: [Int]
    let point: CGPoint
    let depth: CGFloat
}

private struct CommunityRegion: Identifiable {
    let id: String
    let title: String
    let isDemoTopic: Bool
    let members: [CommunityMember]
    let center: Point3D
}

private struct SemanticAtlasRegion {
    let id: String
    let center: Point3D
    let color: Color
    let landRadius: CGFloat
}

private enum AdministrativeLevel {
    case province
    case city
    case district
}

/// Generates a short, deterministic label from all content in a region.
/// This is the offline fallback while the compact generative Judge is not part
/// of the simplified app target. It never uses a single representative title.
private enum SemanticPlaceNameEngine {
    private struct Theme {
        let name: String
        let evidence: [String]
    }

    private static let themes = [
        Theme(name: "哲学思辨", evidence: ["哲学", "自由意志", "道德", "知识", "身份", "意识", "存在", "主观"]),
        Theme(name: "软件工程", evidence: ["Swift", "Rust", "编程", "代码", "数据库", "索引", "iOS", "并发", "内存", "算法"]),
        Theme(name: "烹饪饮食", evidence: ["烹饪", "炒", "面团", "烤箱", "晚餐", "花椒", "意面", "鸡蛋", "番茄"]),
        Theme(name: "宇宙天文", evidence: ["天文", "星系", "黑洞", "望远镜", "木星", "脉冲星", "卫星", "宇宙"]),
        Theme(name: "园艺植物", evidence: ["园艺", "植物", "薄荷", "多肉", "土壤", "绣球花", "幼苗", "花盆"]),
        Theme(name: "音乐创作", evidence: ["音乐", "爵士", "钢琴", "交响曲", "合成器", "和声", "节奏", "乐章"]),
        Theme(name: "金融经济", evidence: ["金融", "债券", "利率", "预算", "储蓄", "投资", "现金流", "利润"]),
        Theme(name: "运动训练", evidence: ["运动", "跑步", "公里", "心率", "力量训练", "肌肉", "游泳", "羽毛球"]),
        Theme(name: "历史人文", evidence: ["历史", "丝绸之路", "唐代", "工业革命", "家族", "贸易", "旧照片"]),
        Theme(name: "医疗健康", evidence: ["医疗", "发烧", "体温", "疫苗", "免疫", "睡眠", "血压", "牙医", "疼痛"]),
        Theme(name: "旅行探索", evidence: ["旅行", "行程", "冰岛", "极光", "东京", "地铁", "徒步", "海边", "小镇"]),
        Theme(name: "文学写作", evidence: ["文学", "小说", "诗歌", "叙述者", "意象", "短篇", "作家", "写作"]),
    ]

    private static let details = [
        "自由意志", "知识", "身份", "道德", "Swift", "Rust", "数据库", "iOS", "并发", "内存",
        "番茄炒蛋", "发酵", "花椒", "意面", "早期星系", "黑洞", "木星", "脉冲星",
        "薄荷", "多肉", "绣球花", "番茄幼苗", "爵士乐", "钢琴", "交响曲", "电子舞曲",
        "债券", "家庭预算", "分散投资", "现金流", "跑步", "力量训练", "自由泳", "羽毛球",
        "丝绸之路", "唐代城市", "工业革命", "家族故事", "体温", "疫苗", "睡眠", "牙齿",
        "冰岛极光", "东京地铁", "山谷徒步", "海边生活", "小说叙事", "诗歌意象", "未来城市", "孤独主题"
    ]

    static func name(contents: [String], level: AdministrativeLevel) -> String {
        let documents = contents.map { $0.lowercased() }.filter { !$0.isEmpty }
        guard !documents.isEmpty else { return "未命名" }
        let themeScores = themes.map { theme in
            (theme, theme.evidence.reduce(0) { score, word in
                score + documents.reduce(0) { $0 + ($1.contains(word.lowercased()) ? 1 : 0) }
            })
        }.sorted { $0.1 > $1.1 }
        let theme = themeScores.first(where: { $0.1 > 0 })?.0
        if level == .province, let theme { return theme.name }

        var detailScores: [(String, Int)] = []
        for detail in details {
            let needle = detail.lowercased()
            var score = 0
            for document in documents where document.contains(needle) { score += 1 }
            if score > 0 { detailScores.append((detail, score)) }
        }
        let rankedDetails = detailScores.sorted { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0.count > rhs.0.count : lhs.1 > rhs.1
        }
        if let first = rankedDetails.first?.0 {
            if level == .district, let second = rankedDetails.dropFirst().first?.0, first != second {
                return String("\(first)·\(second)".prefix(8))
            }
            return String(first.prefix(7))
        }
        if let theme { return theme.name }
        return fallbackKeyword(documents) ?? "未命名"
    }

    private static func fallbackKeyword(_ documents: [String]) -> String? {
        let ignored = ["今天", "一个", "可以", "如何", "什么", "其中", "不同", "相关", "内容", "问题", "记录", "思考", "看看", "尝试"]
        var scores: [String: Int] = [:]
        for document in documents {
            let characters = Array(document.filter { !$0.isWhitespace && !$0.isPunctuation })
            guard characters.count >= 2 else { continue }
            var seen = Set<String>()
            for length in 2...min(4, characters.count) {
                for start in 0...(characters.count - length) {
                    let candidate = String(characters[start..<(start + length)])
                    guard !ignored.contains(where: { candidate.contains($0) || $0.contains(candidate) }),
                          candidate.unicodeScalars.contains(where: { $0.properties.isIdeographic }) else { continue }
                    seen.insert(candidate)
                }
            }
            for candidate in seen { scores[candidate, default: 0] += 1 }
        }
        return scores.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key.count < rhs.key.count : lhs.value < rhs.value
        }.map { String($0.key.prefix(6)) }
    }
}

private struct AdministrativeLabel: Identifiable {
    let id: String
    let level: AdministrativeLevel
    let defaultName: String
    let center: Point3D
    let color: Color
}

private struct PlaceNamesEditorView: View {
    let labels: [AdministrativeLabel]
    @Binding var overrides: [String: String]

    var body: some View {
        List {
            ForEach([AdministrativeLevel.province, .city, .district], id: \.self) { level in
                Section(level.title) {
                    ForEach(labels.filter { $0.level == level }) { label in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Circle().fill(label.color).frame(width: 9, height: 9)
                                TextField(
                                    label.defaultName,
                                    text: Binding(
                                        get: { overrides[label.id] ?? label.defaultName },
                                        set: { value in
                                            let cleaned = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(16))
                                            if cleaned.isEmpty || cleaned == label.defaultName {
                                                overrides.removeValue(forKey: label.id)
                                            } else {
                                                overrides[label.id] = cleaned
                                            }
                                        }
                                    )
                                )
                                .textInputAutocapitalization(.never)
                                if overrides[label.id] != nil {
                                    Button {
                                        overrides.removeValue(forKey: label.id)
                                    } label: {
                                        Image(systemName: "arrow.uturn.backward.circle")
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("恢复缺省名称")
                                }
                            }
                            Text("缺省：\(label.defaultName)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("编辑地图名称")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private extension AdministrativeLevel {
    var title: String {
        switch self {
        case .province: "省"
        case .city: "市"
        case .district: "区"
        }
    }
}

private struct CommunityMember: Identifiable {
    var id: PointID { point.id }
    let point: PointSummary
    let content: String
}

private struct PlanetDemoPoint: Codable, Identifiable {
    let id: UUID
    let topic: String
    let communityID: String
    let text: String
    let latitude: Double
    let longitude: Double

    static func load() -> [Self] {
        guard let url = Bundle.main.url(forResource: "PlanetDemoPoints", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let points = try? JSONDecoder().decode([Self].self, from: data) else { return [] }
        return points
    }
}

private struct PlanetDistributionDemoView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selected: PlanetDemoPoint?
    private let samples = PlanetDemoPoint.load()

    private var layout: StarLayout {
        StarLayout(
            nodes: samples.map { sample in
                let latitude = CGFloat(sample.latitude) * .pi / 180
                let longitude = CGFloat(sample.longitude) * .pi / 180
                return StarLayout.Node(
                    point: PointSummary(
                        id: PointID(rawValue: sample.id),
                        title: sample.text,
                        createdAt: .distantPast,
                        transcriptState: "text"
                    ),
                    position: Point3D(
                        x: cos(latitude) * sin(longitude),
                        y: sin(latitude),
                        z: cos(latitude) * cos(longitude)
                    ),
                    isEmbedded: true
                )
            },
            links: [],
            embeddingCount: samples.count
        )
    }

    private var geographies: [PointID: PointGeographyRecord] {
        Dictionary(uniqueKeysWithValues: samples.map { sample in
            let pointID = PointID(rawValue: sample.id)
            return (pointID, PointGeographyRecord(
                pointID: pointID,
                geographyVersion: GeographyIdentity.relativeSemanticV6,
                contentRevision: 1,
                communityID: sample.communityID,
                latitude: sample.latitude,
                longitude: sample.longitude,
                placementConfidence: 0
            ))
        })
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.02, green: 0.08, blue: 0.16), .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ).ignoresSafeArea()

            if samples.isEmpty {
                ContentUnavailableView("演示数据未打包", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.white)
            } else {
                SemanticGlobe(
                    layout: layout,
                    geographies: geographies,
                    contentByPointID: Dictionary(uniqueKeysWithValues: samples.map { (PointID(rawValue: $0.id), $0.text) }),
                    topicByPointID: Dictionary(uniqueKeysWithValues: samples.map { (PointID(rawValue: $0.id), $0.topic) }),
                    initialYaw: -.pi / 2,
                    initialZoom: 1.2
                ) { point in
                    selected = samples.first { $0.id == point.id.rawValue }
                }
            }
        }
        .navigationTitle("球面分布 Demo")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            Button("完成") { dismiss() }.tint(.white)
        }
        .safeAreaInset(edge: .bottom) {
            Text("\(samples.count) 条 · 颜色为算法分区 · 点开可对照人工主题 · 旋转查看背面")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.8))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(.black.opacity(0.75))
        }
        .sheet(item: $selected) { sample in
            NavigationStack {
                VStack(alignment: .leading, spacing: 18) {
                    Text(sample.topic)
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Text(sample.text)
                        .font(.title3)
                    Text("纬度 \(sample.latitude, format: .number.precision(.fractionLength(2)))° · 经度 \(sample.longitude, format: .number.precision(.fractionLength(2)))°")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding()
                .navigationTitle("演示词句")
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium])
        }
    }
}

private enum SphericalLayoutEngine {
    /// Relaxes points directly on a unit sphere. Similarity controls the desired
    /// angular separation: stronger E5 links settle into a visibly tighter area.
    static func make(layout: StarLayout) -> [Point3D] {
        guard layout.nodes.count > 1 else {
            return layout.nodes.map { $0.position.normalized }
        }

        var positions = layout.nodes.map { $0.position.normalized }
        let linkByPair = Dictionary(uniqueKeysWithValues: layout.links.map {
            (pairKey($0.a, $0.b), $0.strength)
        })

        for iteration in 0..<160 {
            var forces = Array(repeating: Point3D(x: 0, y: 0, z: 0), count: positions.count)
            for i in positions.indices {
                for j in positions.indices where j > i {
                    let dot = min(1, max(-1, dot(positions[i], positions[j])))
                    let angle = max(0.025, acos(dot))
                    let towardJ = tangent(from: positions[i], toward: positions[j])
                    let towardI = tangent(from: positions[j], toward: positions[i])

                    // A small global repulsion keeps unrelated leaves readable.
                    let repulsion = min(0.018, 0.0018 / (angle * angle + 0.018))
                    forces[i] = forces[i] - towardJ * repulsion
                    forces[j] = forces[j] - towardI * repulsion

                    guard let strength = linkByPair[pairKey(i, j)] else { continue }
                    let normalizedStrength = min(1, max(0, (strength - 0.85) / 0.15))
                    // 0.85 similarity ≈ 29°, 1.0 similarity ≈ 5°.
                    let targetAngle = 0.50 - normalizedStrength * 0.41
                    let attraction = (angle - targetAngle) * (0.018 + normalizedStrength * 0.034)
                    forces[i] = forces[i] + towardJ * attraction
                    forces[j] = forces[j] + towardI * attraction
                }
            }

            let cooling = 0.3 + 0.7 * CGFloat(160 - iteration) / 160
            for index in positions.indices {
                positions[index] = (positions[index] + forces[index] * cooling).normalized
            }
        }
        return positions
    }

    private static func pairKey(_ lhs: Int, _ rhs: Int) -> String {
        lhs < rhs ? "\(lhs):\(rhs)" : "\(rhs):\(lhs)"
    }

    private static func dot(_ lhs: Point3D, _ rhs: Point3D) -> CGFloat {
        lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z
    }

    private static func tangent(from origin: Point3D, toward target: Point3D) -> Point3D {
        let projected = target - origin * dot(origin, target)
        return projected.length > 0.0001 ? projected.normalized : Point3D(x: 0, y: 0, z: 0)
    }
}
