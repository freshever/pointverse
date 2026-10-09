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
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    NotificationCenter.default.post(name: AppContainer.enterTestMode, object: nil)
                } label: {
                    Label("测试模式", systemImage: "flask.fill")
                }
                .tint(.white)
                Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                    .tint(.white)
            }
        }
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: AppContainer.testDataDidChange)) { _ in
            Task { await reload() }
        }
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

private struct StarMapTestModeView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var database: PointDatabase?
    @State private var entries: [PointMapEntry] = []
    @State private var layout = StarLayout(nodes: [], links: [], embeddingCount: 0)
    @State private var selectedEntry: PointMapEntry?
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.08, green: 0.035, blue: 0.12), .black],
                startPoint: .top,
                endPoint: .bottom
            ).ignoresSafeArea()

            if isWorking && entries.isEmpty {
                ProgressView("正在准备独立测试库").tint(.white).foregroundStyle(.white)
            } else if layout.nodes.isEmpty {
                ContentUnavailableView {
                    Label("测试库为空", systemImage: "flask")
                } description: {
                    Text("点击“+100”生成跨主题纯文本 Point。")
                } actions: {
                    Button("+100 条测试文本") { Task { await appendSamples(count: 100) } }
                        .buttonStyle(.borderedProminent)
                }
                .foregroundStyle(.white)
            } else {
                Pseudo3DStarMap(layout: layout) { point in
                    selectedEntry = entries.first { $0.id == point.id }
                }
            }

            VStack {
                Spacer()
                HStack(spacing: 10) {
                    Label("独立测试库", systemImage: "externaldrive.badge.checkmark")
                    Text("\(entries.count) 条")
                    if isWorking { ProgressView().controlSize(.small).tint(.white) }
                }
                .font(.caption.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.purple.opacity(0.78), in: Capsule())
                .padding(.bottom, 76)
            }
        }
        .navigationTitle("星图测试模式")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(Color(red: 0.08, green: 0.035, blue: 0.12), for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    Task { await appendSamples(count: 100) }
                } label: {
                    Label("+100", systemImage: "plus.circle.fill")
                }
                .disabled(isWorking)
                Menu {
                    Button("清空测试库", role: .destructive) {
                        Task { await clearSamples() }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(isWorking || entries.isEmpty)
            }
        }
        .task { await openDatabase() }
        .sheet(item: $selectedEntry) { entry in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(entry.point.title).font(.title3.bold())
                        Text(entry.content).font(.body).textSelection(.enabled)
                        Divider()
                        Text("这条内容只存在于测试数据库，不会进入正式 Point 列表。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
                .navigationTitle("测试文本")
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium])
        }
        .alert("测试模式出错", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func openDatabase() async {
        guard database == nil else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let opened = try await container.makeTestModeDatabase()
            database = opened
            await reload(from: opened)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func appendSamples(count: Int) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let target: PointDatabase
            if let database {
                target = database
            } else {
                target = try await container.makeTestModeDatabase()
                database = target
            }
            let start = try await target.listPoints(matching: "").count
            for text in TestTextFactory.make(count: count, startingAt: start) {
                _ = try await target.commitTextPoint(text: text)
            }
            _ = await container.refreshTestModeEmbeddings(in: target)
            await reload(from: target)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clearSamples() async {
        guard let database, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            for point in try await database.listPoints(matching: "") {
                _ = try await database.deletePoint(id: point.id)
            }
            await reload(from: database)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reload(from database: PointDatabase) async {
        do {
            async let loadedEntries = database.pointMapEntries()
            async let loadedEmbeddings = database.embeddings(modelID: EmbeddingModelIdentity.multilingualE5Small)
            let values = try await loadedEntries
            entries = values
            layout = StarLayoutEngine.make(entries: values, embeddings: try await loadedEmbeddings)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

enum TestTextFactory {
    private static let perspectives = [
        "我想先理解它背后的原理", "下一步需要设计一个小实验", "可以从实际使用场景继续观察", "这件事值得记录长期变化",
        "我还需要寻找一个相反的例子", "也许可以和另一个领域建立联系", "先列出最重要的限制条件", "需要区分短期现象和长期趋势",
        "可以向有经验的人验证这个判断", "以后回看时要保留当时的背景"
    ]
    private static let topics: [[String]] = [
        ["Transformer 的注意力机制如何保留长文本上下文", "给本地模型设计低内存推理管线", "Swift 并发中的 actor 可以隔离可变状态", "向量数据库需要评估召回率和延迟", "Core ML 模型量化会影响精度与功耗", "软件架构应该保持模块边界清晰", "为语义搜索建立可靠的人工评测集", "离线 AI 应优先保护用户隐私", "调试神经网络输出需要保存中间张量", "代码审查要重点检查状态竞争"],
        ["番茄炖牛肉需要控制火候和水量", "尝试用低温烘焙保留面包的水分", "咖啡豆研磨粗细会改变萃取速度", "晚餐准备一道清淡的时蔬汤", "发酵面团要观察温度与时间", "记录不同产区茶叶的香气变化", "煎鱼前擦干表面可以减少粘锅", "研究香料在咖喱中的层次组合", "早餐增加蛋白质会更有饱腹感", "周末学习制作手工意大利面"],
        ["阳台上的薄荷需要避免中午暴晒", "春天适合给月季修剪和换盆", "观察番茄幼苗每天的生长高度", "给多肉植物减少冬季浇水频率", "堆肥中的落叶需要保持适度湿润", "设计一个吸引蜜蜂的小型花园", "兰花的新根说明环境湿度合适", "雨后检查花盆是否存在积水", "用扦插方法繁殖迷迭香", "记录植物叶片颜色与光照的关系"],
        ["木星大红斑是一场持续很久的风暴", "银河系中心存在超大质量黑洞", "计划在无月夜观察英仙座流星雨", "恒星光谱可以揭示化学组成", "引力透镜能够放大遥远星系", "火星土壤保存着古代水活动证据", "望远镜口径决定集光能力", "宇宙微波背景记录早期宇宙信息", "土星环由大量冰和岩石碎片构成", "系外行星可以通过凌日法发现"],
        ["每周进行三次有氧运动改善耐力", "深蹲动作要保持膝盖方向稳定", "长跑训练需要逐步增加里程", "游泳时调整呼吸可以提升效率", "运动后补充水分和电解质", "核心力量训练能够保护腰背", "骑行前检查刹车和轮胎压力", "睡眠质量会直接影响运动恢复", "热身可以降低突然冲刺的受伤风险", "记录心率区间来调整训练强度"],
        ["莫奈用光线变化表现同一处风景", "爵士即兴建立在和声与节奏之上", "小说中的不可靠叙述者会改变读者判断", "练习钢琴旋律时先放慢速度", "电影剪辑通过镜头顺序创造意义", "水彩画要利用纸面水分形成渐变", "诗歌的停顿可以强化语言节奏", "摄影构图中的留白能够突出主体", "戏剧冲突推动角色作出选择", "博物馆展览需要建立清晰叙事线索"],
        ["制定月度预算并区分固定与弹性支出", "指数基金适合长期分散投资", "购买保险前要理解免责条款", "现金流比账面收入更能反映经营状态", "利率变化会影响债券价格", "建立应急资金应覆盖数月生活成本", "复利需要足够长的时间才能显现", "投资决策不应只依赖短期涨跌", "比较产品价格时也要考虑使用寿命", "创业计划需要先验证真实付费需求"],
        ["旅行前把离线地图下载到手机", "京都清晨的寺院比午后更安静", "徒步路线要提前确认天气和补给点", "海边摄影适合利用日落前的柔光", "博物馆行程应该预留休息时间", "乘坐夜车可以节省一晚住宿", "出国前检查护照有效期和签证", "高原旅行需要给身体适应时间", "学习几句当地语言会让交流更自然", "把旅行见闻按地点和日期整理"],
        ["情绪低落时先识别身体上的紧张感", "重要谈话应该先确认彼此的理解", "给自己留出不被打扰的独处时间", "长期压力可能影响睡眠和注意力", "写日记可以帮助梳理复杂感受", "表达边界不等于拒绝所有关系", "面对冲突时先描述事实而非评价", "对未知的焦虑常来自失去控制感", "建立稳定习惯比追求一次完美更可靠", "倾听时不要急着提供解决方案"],
        ["古代城市通常沿河流和贸易路线发展", "工业革命改变了劳动和家庭结构", "丝绸之路连接了不同文明的商品与观念", "印刷术降低了知识传播成本", "考古遗址需要结合地层判断年代", "航海技术推动了全球贸易网络", "历史记录往往带有书写者的立场", "城市城墙反映当时的防御需求", "货币制度演变影响国家治理能力", "口述史能够补充正式档案的空白"]
    ]

    static func make(count: Int, startingAt start: Int) -> [String] {
        guard count > 0 else { return [] }
        return (start..<(start + count)).map { index in
            let topic = index % topics.count
            let variant = (index / topics.count) % topics[topic].count
            let perspective = perspectives[(index / (topics.count * topics[topic].count)) % perspectives.count]
            return topics[topic][variant] + "，" + perspective
        }
    }
}

private struct Pseudo3DStarMap: View {
    private let minimumZoom: CGFloat = 0.55
    private let maximumZoom: CGFloat = 12
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
                        let emphasis = max(0, min(1, (link.strength - 0.38) / 0.62))
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
                    Text("\(selected ? "当前候选" : "最高候选") · 相对关联度 \(link.strength, format: .number.precision(.fractionLength(3)))")
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
            withAnimation(.easeInOut(duration: 0.22)) {
                zoom = min(maximumZoom, max(minimumZoom, zoom * factor))
            }
        } label: {
            Image(systemName: systemName).foregroundStyle(.white)
                .frame(width: 32, height: 32).background(.white.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
    }

    private func linkColor(_ score: CGFloat) -> Color {
        score >= 0.75 ? .mint : score >= 0.55 ? .cyan : .indigo
    }

    private func relationLevel(_ score: CGFloat) -> String {
        score >= 0.75 ? "高候选" : score >= 0.55 ? "中候选" : "低候选"
    }

    private var rotationGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if dragStartYaw == nil { dragStartYaw = yaw; dragStartPitch = pitch }
                // Slow rotation as the camera moves closer so dense points can
                // be positioned precisely instead of flying past the viewport.
                let sensitivity = 0.008 / sqrt(max(1, zoom))
                yaw = (dragStartYaw ?? yaw) + value.translation.width * sensitivity
                pitch = min(.pi / 2, max(-.pi / 2, (dragStartPitch ?? pitch) + value.translation.height * sensitivity))
            }
            .onEnded { _ in dragStartYaw = nil; dragStartPitch = nil }
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if zoomStart == nil { zoomStart = zoom }
                zoom = min(maximumZoom, max(minimumZoom, (zoomStart ?? zoom) * value))
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
                withAnimation(.easeInOut(duration: 0.3)) {
                    zoom = min(maximumZoom, max(1.12, zoom * 1.45))
                }
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
        case 1.18..<1.55: threshold = 0.75
        case 0.88..<1.18: threshold = 0.55
        default: threshold = 0.38
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

struct Point3D {
    var x: CGFloat
    var y: CGFloat
    var z: CGFloat
    static func + (lhs: Self, rhs: Self) -> Self { .init(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z) }
    static func - (lhs: Self, rhs: Self) -> Self { .init(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z) }
    static func * (lhs: Self, rhs: CGFloat) -> Self { .init(x: lhs.x * rhs, y: lhs.y * rhs, z: lhs.z * rhs) }
    var length: CGFloat { sqrt(x * x + y * y + z * z) }
    var normalized: Self { self * (1 / max(length, 0.001)) }
}

struct StarLayout {
    let nodes: [Node]
    let links: [Link]
    let embeddingCount: Int
    var usesBGE: Bool { embeddingCount > 0 }
    var strongestLink: Link? { links.max { $0.strength < $1.strength } }
    struct Node { let point: PointSummary; let position: Point3D; let isEmbedded: Bool }
    struct Link { let a: Int; let b: Int; let strength: CGFloat }
}

@MainActor
enum StarLayoutEngine {
    static func make(entries: [PointMapEntry], embeddings: [PointEmbeddingRecord]) -> StarLayout {
        guard !entries.isEmpty else { return .init(nodes: [], links: [], embeddingCount: 0) }
        let stored = Dictionary(uniqueKeysWithValues: embeddings.map { ($0.pointID, $0.vector.map(Double.init)) })
        let vectors = entries.map { stored[$0.id] ?? semanticVector(text: $0.content, locale: $0.localeIdentifier) }
        let relativeStored = relativeVectors(
            Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
                stored[entry.id].map { (entry.id, $0) }
            })
        )
        let usesRelativeScores = stored.count >= 3
        var similarities = Array(repeating: Array(repeating: CGFloat(0), count: entries.count), count: entries.count)
        for i in entries.indices {
            for j in entries.indices where j > i {
                let value: CGFloat
                if let lhs = relativeStored[entries[i].id], let rhs = relativeStored[entries[j].id] {
                    // E5 vectors share a large common component. Comparing the
                    // residuals makes this score describe what distinguishes
                    // two Points inside this collection instead of the model's
                    // high global cosine baseline.
                    let score = cosine(lhs, rhs) ?? 0
                    value = usesRelativeScores
                        ? CGFloat(score)
                        : CGFloat(sqrt(min(1, max(0, (score - 0.84) / 0.07))))
                } else {
                    value = CGFloat(cosine(vectors[i], vectors[j])
                        ?? lexicalSimilarity(entries[i].content, entries[j].content))
                }
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
                    if relatedness >= 0.30 {
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
        var degree = Array(repeating: 0, count: entries.count)
        for i in entries.indices {
            let candidates = entries.indices.filter { $0 != i }.sorted { similarities[i][$0] > similarities[i][$1] }
            for j in candidates {
                let bothEmbedded = stored[entries[i].id] != nil && stored[entries[j].id] != nil
                let threshold: CGFloat = bothEmbedded ? 0.38 : (stored.isEmpty ? 0.28 : .infinity)
                guard similarities[i][j] >= threshold else { continue }
                let a = min(i, j), b = max(i, j)
                guard degree[a] < 3, degree[b] < 3 else { continue }
                if used.insert("\(a):\(b)").inserted {
                    links.append(.init(a: a, b: b, strength: similarities[i][j]))
                    degree[a] += 1
                    degree[b] += 1
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

    /// The globe gets positions from persisted geography and draws no star-map
    /// links. Building its view model must therefore stay O(N), without an
    /// unused N×N similarity matrix or a second force-directed layout.
    static func makeGlobe(entries: [PointMapEntry], embeddedPointIDs: Set<PointID>) -> StarLayout {
        StarLayout(
            nodes: entries.map {
                .init(
                    point: $0.point,
                    position: Point3D(x: 0, y: 0, z: 1),
                    isEmbedded: embeddedPointIDs.contains($0.id)
                )
            },
            links: [],
            embeddingCount: embeddedPointIDs.count
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

    private static func relativeVectors(_ vectors: [PointID: [Double]]) -> [PointID: [Double]] {
        guard vectors.count >= 3, let dimension = vectors.values.first?.count, dimension > 0,
              vectors.values.allSatisfy({ $0.count == dimension }) else { return vectors }
        var centroid = Array(repeating: 0.0, count: dimension)
        for vector in vectors.values {
            for index in 0..<dimension { centroid[index] += vector[index] }
        }
        centroid = centroid.map { $0 / Double(vectors.count) }
        return vectors.mapValues { vector in
            let residual = zip(vector, centroid).map { $0.0 - $0.1 }
            let norm = sqrt(residual.reduce(0) { $0 + $1 * $1 })
            return norm > 0.000_1 ? residual.map { $0 / norm } : vector
        }
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
