import NaturalLanguage
import PointVerseKit
import SwiftUI

struct StarMapView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var layout = StarLayout(nodes: [], links: [], embeddingCount: 0)
    @State private var entries: [PointMapEntry] = []
    @State private var selected: PointSummary?
    @State private var loadFailed = false
    @State private var showingSearch = false
    @State private var focusRequest: PointMapFocusRequest?

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
                Pseudo3DStarMap(layout: layout, focusRequest: focusRequest) { selected = $0 }
            }
        }
        .navigationTitle("星图")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(Color(red: 0.035, green: 0.045, blue: 0.11), for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showingSearch = true } label: { Image(systemName: "magnifyingglass") }
                    .tint(.white)
                    .accessibilityLabel("搜索 Point")
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
        .sheet(isPresented: $showingSearch) {
            PointMapSearchSheet(entries: entries) { pointID in
                focusRequest = PointMapFocusRequest(pointID: pointID)
                showingSearch = false
            }
        }
        .alert("无法读取星图", isPresented: $loadFailed) { Button("好") {} }
    }

    private func reload() async {
        do {
            async let loadedEntries = container.database.pointMapEntries()
            async let embeddings = container.database.embeddings(modelID: EmbeddingModelIdentity.bgeSmallZhV15)
            let values = try await loadedEntries
            entries = values
            layout = StarLayoutEngine.make(entries: values, embeddings: try await embeddings)
        } catch {
            loadFailed = true
        }
    }
}

struct PointMapFocusRequest: Equatable {
    let pointID: PointID
    private let nonce = UUID()

    init(pointID: PointID) {
        self.pointID = pointID
    }
}

struct PointMapSearchSheet: View {
    let entries: [PointMapEntry]
    let onSelect: (PointID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var results: [PointMapEntry] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = value.isEmpty ? entries : entries.filter {
            $0.point.title.localizedCaseInsensitiveContains(value)
                || $0.content.localizedCaseInsensitiveContains(value)
        }
        return Array(source.sorted { $0.point.createdAt > $1.point.createdAt }.prefix(100))
    }

    var body: some View {
        NavigationStack {
            List(results) { entry in
                Button {
                    onSelect(entry.id)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(entry.point.title.isEmpty ? "未命名 Point" : entry.point.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        if !entry.content.isEmpty {
                            Text(entry.content)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                        Text(entry.point.createdAt, format: .dateTime.year().month().day().hour().minute())
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .navigationTitle("搜索 Point")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "搜索标题或内容")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
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
                Pseudo3DStarMap(layout: layout, focusRequest: nil) { point in
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
    let focusRequest: PointMapFocusRequest?
    let onSelect: (PointSummary) -> Void
    @State private var yaw: CGFloat = 0.35
    @State private var pitch: CGFloat = -0.18
    @State private var dragStartYaw: CGFloat?
    @State private var dragStartPitch: CGFloat?
    @State private var zoom: CGFloat = 1
    @State private var zoomStart: CGFloat?
    @State private var selectedLink: StarLayout.Link?
    @State private var focusedPointID: PointID?

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
                        if focusedPointID == point.id {
                            context.stroke(Path(ellipseIn: rect.insetBy(dx: -10, dy: -10)),
                                           with: .color(.yellow.opacity(0.95)), lineWidth: 3)
                        }
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
                .simultaneousGesture(zoomGesture(size: proxy.size))
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
            .onChange(of: focusRequest) { _, request in
                focus(on: request)
            }
        }
    }

    private func focus(on request: PointMapFocusRequest?) {
        guard let request,
              let node = layout.nodes.first(where: { $0.point.id == request.pointID }) else { return }
        let position = node.position
        let targetYaw = atan2(-position.x, position.z)
        let rotatedDepth = -position.x * sin(targetYaw) + position.z * cos(targetYaw)
        let targetPitch = atan2(position.y, rotatedDepth)
        focusedPointID = request.pointID
        selectedLink = nil
        withAnimation(.easeInOut(duration: 0.55)) {
            yaw = targetYaw
            pitch = targetPitch
            zoom = min(maximumZoom, max(zoom, 8))
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

    private func zoomGesture(size: CGSize) -> some Gesture {
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
        let focusedIndex = focusedPointID.flatMap { id in layout.nodes.firstIndex { $0.point.id == id } }
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
                    if let neighbor, neighbor != focusedIndex, current != focusedIndex,
                       remaining.remove(neighbor) != nil {
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

struct UniverseMapView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var entries: [PointMapEntry] = []
    @State private var layout = StarLayout(nodes: [], links: [], embeddingCount: 0)
    @State private var geographies: [PointID: PointGeographyRecord] = [:]
    @State private var contentByPointID: [PointID: String] = [:]
    @State private var selected: PointSummary?
    @State private var showingSearch = false
    @State private var focusRequest: PointMapFocusRequest?
    @State private var loadFailed = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.025, green: 0.018, blue: 0.09), .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            if layout.nodes.isEmpty {
                ContentUnavailableView {
                    Label("宇宙尚未形成", systemImage: "hurricane")
                } description: {
                    Text("记录更多想法后，相关 Point 会逐渐形成星球与星系。")
                }
                .foregroundStyle(.white)
            } else {
                SemanticUniverse(
                    layout: layout,
                    geographies: geographies,
                    contentByPointID: contentByPointID,
                    focusRequest: focusRequest
                ) { selected = $0 }
            }
        }
        .navigationTitle("语义宇宙")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(Color(red: 0.025, green: 0.018, blue: 0.09), for: .navigationBar)
        .toolbar {
            Button { showingSearch = true } label: { Image(systemName: "magnifyingglass") }
                .tint(.white)
            Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                .tint(.white)
        }
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: EmbeddingService.didChangeNotification)) { _ in
            Task { await reload() }
        }
        .sheet(isPresented: $showingSearch) {
            PointMapSearchSheet(entries: entries) { pointID in
                focusRequest = PointMapFocusRequest(pointID: pointID)
                showingSearch = false
            }
        }
        .sheet(item: $selected) { point in
            NavigationStack { PointDetailView(point: point) }
                .environmentObject(container)
                .presentationDetents([.medium, .large])
        }
        .alert("无法读取语义宇宙", isPresented: $loadFailed) { Button("好") {} }
    }

    private func reload() async {
        do {
            async let loadedEntries = container.database.pointMapEntries()
            async let embeddings = container.database.embeddings(modelID: EmbeddingModelIdentity.bgeSmallZhV15)
            async let storedGeographies = container.database.geographies(version: GeographyIdentity.relativeSemanticV6)
            let values = try await loadedEntries
            let loadedGeographies = try await storedGeographies
            entries = values
            layout = StarLayoutEngine.make(entries: values, embeddings: try await embeddings)
            geographies = Dictionary(uniqueKeysWithValues: loadedGeographies.map { ($0.pointID, $0) })
            contentByPointID = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0.content) })
        } catch {
            loadFailed = true
        }
    }
}

private struct SemanticUniverse: View {
    // These are numerical guards only, not user-facing zoom limits.
    private let minimumZoom: CGFloat = 0.0001
    // A numerical safety ceiling only; there is no content-based UI limit.
    private let maximumZoom: CGFloat = 1_000_000_000_000
    let layout: StarLayout
    let geographies: [PointID: PointGeographyRecord]
    let contentByPointID: [PointID: String]
    let focusRequest: PointMapFocusRequest?
    let onSelect: (PointSummary) -> Void
    private let hierarchy: CosmicHierarchy
    private let cachedPlanetLayouts: [Int: StarLayout]

    init(layout: StarLayout,
         geographies: [PointID: PointGeographyRecord],
         contentByPointID: [PointID: String],
         focusRequest: PointMapFocusRequest?,
         onSelect: @escaping (PointSummary) -> Void) {
        self.layout = layout
        self.geographies = geographies
        self.contentByPointID = contentByPointID
        self.focusRequest = focusRequest
        self.onSelect = onSelect
        let hierarchy = CosmicHierarchy.make(layout: layout, geographies: geographies)
        self.hierarchy = hierarchy
        self.cachedPlanetLayouts = Dictionary(uniqueKeysWithValues: hierarchy.planets.map { planet in
            let oldIndices = planet.nodeIndices
            let remap = Dictionary(uniqueKeysWithValues: oldIndices.enumerated().map { ($0.element, $0.offset) })
            let nodes = oldIndices.map { layout.nodes[$0] }
            let links = layout.links.compactMap { link -> StarLayout.Link? in
                guard let a = remap[link.a], let b = remap[link.b] else { return nil }
                return .init(a: a, b: b, strength: link.strength)
            }
            return (planet.id, StarLayout(nodes: nodes, links: links,
                                          embeddingCount: nodes.filter(\.isEmbedded).count))
        })
    }

    @State private var zoom: CGFloat = 0.75
    @State private var zoomOrigin: CGFloat?
    @State private var camera = CGPoint.zero
    @State private var dragOrigin: CGPoint?
    @State private var focusedPointID: PointID?
    @State private var activePlanetID: Int?
    @State private var cameraTargetPlanetID: Int?
    @State private var planetFocusProgress: CGFloat = 0
    @State private var universeZoomBeforeEntry: CGFloat = 2.2
    @State private var surfaceEntryCameraDistance: CGFloat = 0
    @State private var planetYaw: CGFloat = 0
    @State private var planetPitch: CGFloat = 0
    @State private var surfaceRotationOrigin: CGPoint?
    @State private var surfaceZoom: CGFloat = 1
    @State private var viewportSize: CGSize = .zero
    @State private var didCenterInitialCamera = false
    @State private var cameraMagnificationOrigin: CGFloat?
    @State private var cameraMagnificationDiameterOrigin: CGFloat?
    @State private var cameraMagnificationDistanceOrigin: CGFloat?
    @State private var magnificationPlanetID: Int?
    @State private var magnificationPlanetScreenAnchor: CGPoint?
    @State private var cameraAnimationToken = UUID()

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Canvas { context, size in draw(context: &context, size: size) }
                .contentShape(Rectangle())
                .gesture(panGesture(size: proxy.size))
                .simultaneousGesture(zoomGesture(size: proxy.size))
                .simultaneousGesture(
                    SpatialTapGesture().onEnded { value in handleTap(at: value.location, size: proxy.size) }
                )

                ForEach(hierarchy.planets.sorted { planetWorldPosition($0).z < planetWorldPosition($1).z }, id: \.id) { planet in
                    let selected = activePlanetID == planet.id
                    let universeCenter = planetScreenPosition(planet, size: proxy.size)
                    let diameter = planetVisualRadius(planet, size: proxy.size) * 2
                    let showsDetailedSurface = diameter >= surfaceRevealDiameter(for: proxy.size)
                    // Instantiate the full province/city/district renderer only
                    // for a selected or genuinely near planet. Far planets use
                    // the cheap Canvas LOD below. The two renderers are mutually
                    // exclusive, so the map replaces the very same projected
                    // sphere instead of drawing a second sphere over it.
                    if isPlanetOnScreen(planet, size: proxy.size),
                       preparesDetailedRenderer(planet, size: proxy.size) {
                        SemanticGlobe(
                            layout: planetLayout(planet),
                            geographies: geographies,
                            contentByPointID: contentByPointID,
                            initialZoom: 1,
                            focusRequest: selected ? focusedPointID.map(PointMapFocusRequest.init(pointID:)) : nil,
                            onZoomOut: nil,
                            showsChrome: false,
                            externalZoom: 1,
                            onZoomChanged: nil,
                            planetTint: cosmicColor(planet.id + 31),
                            cameraDriven: true,
                            embeddedInUniverse: true,
                            // Surface detail grows continuously from the early
                            // quarter-screen reveal to the fitted map scale.
                            detailZoomOverride: max(0.28, diameter / fittedPlanetDiameter(for: proxy.size)),
                            onCameraMagnificationChanged: { updateCameraMagnification($0) },
                            onCameraMagnificationEnded: { finishCameraMagnification() },
                            onInteractionBegan: { activatePlanetSurface(planet) },
                            onSelect: onSelect
                        )
                        .frame(width: max(28, diameter), height: max(28, diameter))
                        .contentShape(Circle())
                        // The globe owns drags once its surface is visible,
                        // but a tap must still reach the universe camera so
                        // an already-interactive, off-centre planet can be
                        // brought to the middle of the viewport.
                        .simultaneousGesture(
                            TapGesture().onEnded { centerCamera(on: planet) }
                        )
                        .position(universeCenter)
                        // Prepare the map before it is needed. Crossing the LOD
                        // threshold then only swaps surface detail; it never
                        // creates a newly scaling planet during camera travel.
                        .opacity(showsDetailedSurface ? 1 : 0)
                        .allowsHitTesting(showsDetailedSurface)
                        .id("universe-planet-\(planet.id)")
                        .transition(.identity)
                    }
                }

                // Detailed globes replace the cheap Canvas sphere, but their
                // planet identity still belongs to the universe layer. Keep a
                // stable label above every revealed surface instead of losing
                // the name at the LOD handoff.
                ForEach(hierarchy.planets, id: \.id) { planet in
                    let center = planetScreenPosition(planet, size: proxy.size)
                    let radius = planetVisualRadius(planet, size: proxy.size)
                    if radius * 2 >= surfaceRevealDiameter(for: proxy.size),
                       isPlanetOnScreen(planet, size: proxy.size) {
                        Text(planet.name)
                            .font(radius >= 150 ? .headline.bold() : .caption.bold())
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.55), in: Capsule())
                            .overlay(Capsule().stroke(.white.opacity(0.18)))
                            .position(
                                x: center.x,
                                y: max(76, center.y - radius - 16)
                            )
                            .allowsHitTesting(false)
                    }
                }

                VStack {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Label(levelTitle, systemImage: levelIcon)
                                .font(.caption.bold())
                            Text("缩放穿越：恒星系 → 行星与卫星 → 行星地图 → Point")
                                .font(.caption2).foregroundStyle(.white.opacity(0.6))
                        }
                        Spacer()
                        Text("\(hierarchy.galaxies.count) 恒星系 · \(hierarchy.planets.count) 行星")
                            .font(.caption2.monospacedDigit())
                    }
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
                    .padding()
                    Spacer()
                    HStack(spacing: 12) {
                        universeControl("minus.magnifyingglass") { changeZoom(0.7) }
                        universeControl("plus.magnifyingglass") { changeZoom(1.45) }
                        Divider().frame(height: 22).overlay(.white.opacity(0.22))
                        Button("全景") {
                            focusedPointID = nil
                            activePlanetID = nil
                            cameraTargetPlanetID = nil
                            surfaceEntryCameraDistance = 0
                            let overview = universeOverview(size: proxy.size)
                            animateUniverseCamera(to: overview.camera, zoom: overview.zoom, duration: 0.4)
                        }
                        .font(.caption.bold()).foregroundStyle(.white)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.black.opacity(0.7), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.2)))
                    .padding(.bottom, 18)
                }
            }
            .onChange(of: focusRequest) { _, request in focus(on: request) }
            .onAppear { viewportSize = proxy.size; centerInitialCameraIfNeeded(size: proxy.size) }
            .onChange(of: proxy.size) { _, value in viewportSize = value }
        }
    }

    private func exitPlanet() {
        surfaceZoom = 1
        planetFocusProgress = 0
        focusedPointID = nil
        activePlanetID = nil
        cameraTargetPlanetID = nil
    }

    private func updateFocusedPlanetZoom(_ value: CGFloat) {
        // Split the visual scale between the reusable globe's frame and its
        // own map zoom. Their product remains linear and avoids a sudden jump.
        surfaceZoom = value * value
        if value < 0.96 {
            DispatchQueue.main.async { exitPlanet() }
        }
    }

    private func updateCameraMagnification(_ gestureScale: CGFloat) {
        if cameraMagnificationOrigin == nil {
            cameraAnimationToken = UUID()
            cameraMagnificationOrigin = zoom
            cameraMagnificationDistanceOrigin = cameraDistance
            if let planet = cameraDollyPlanet, viewportSize.width > 0 {
                cameraMagnificationDiameterOrigin = planetVisualRadius(planet, size: viewportSize) * 2
            }
        }
        if let planet = cameraDollyPlanet,
           let diameterOrigin = cameraMagnificationDiameterOrigin,
           viewportSize.width > 0 {
            let targetDiameter = min(
                maximumSafeDiameter(for: viewportSize),
                max(0.1, diameterOrigin * max(0.0001, gestureScale))
            )
            zoom = zoom(forPlanetDiameter: targetDiameter, planet: planet, size: viewportSize)
            return
        }
        // In universe space solve the camera curve backwards: a 1.2x pinch
        // produces a 1.2x projected scene at every distance.
        let originDistance = cameraMagnificationDistanceOrigin ?? cameraDistance
        let near = universeCameraNearDistance
        let targetDistance = near + (originDistance - near) / max(0.0001, gestureScale)
        zoom = universeZoom(forCameraDistance: targetDistance)
    }

    private func finishCameraMagnification() {
        cameraMagnificationOrigin = nil
        cameraMagnificationDiameterOrigin = nil
        cameraMagnificationDistanceOrigin = nil
        if let planet = activePlanet,
           viewportSize.width > 0,
           planetVisualRadius(planet, size: viewportSize) * 2 < surfaceRevealDiameter(for: viewportSize) {
            deactivatePlanetSurfaceKeepingCameraTarget()
            releasePlanetCameraIfFarEnough(planet, size: viewportSize)
            return
        }
        activateCenteredSurfaceIfNeeded()
    }

    /// Leaving the detailed-surface LOD must not also change camera space.
    /// Keeping the dolly target makes the simplified and detailed spheres use
    /// one continuous projection and lets the same small planet enlarge again
    /// without requiring another centering tap.
    private func deactivatePlanetSurfaceKeepingCameraTarget() {
        focusedPointID = nil
        activePlanetID = nil
        planetFocusProgress = 0
        surfaceZoom = 1
    }

    /// Switch from the planet-relative dolly curve back to the universe curve
    /// without changing the rendered frame. This is essential after search:
    /// otherwise the searched planet remains the camera's permanent anchor and
    /// zooming out can never return to the multi-planet universe.
    private func releasePlanetCameraIfFarEnough(_ planet: CosmicHierarchy.Planet, size: CGSize) {
        let diameter = planetVisualRadius(planet, size: size) * 2
        guard diameter < surfaceRevealDiameter(for: size) * 0.72 else { return }
        let preservedDistance = cameraDistance
        cameraTargetPlanetID = nil
        surfaceEntryCameraDistance = 0
        zoom = universeZoom(forCameraDistance: preservedDistance)
    }

    private func visiblePlanets() -> [CosmicHierarchy.Planet] {
        guard viewportSize.width > 0 else { return [] }
        let bounds = CGRect(origin: .zero, size: viewportSize).insetBy(dx: -24, dy: -24)
        return hierarchy.planets.filter { planet in
            let center = planetScreenPosition(planet, size: viewportSize)
            let radius = planetVisualRadius(planet, size: viewportSize)
            return bounds.intersects(CGRect(x: center.x - radius, y: center.y - radius,
                                            width: radius * 2, height: radius * 2))
        }
    }

    private func activatePlanetSurface(_ planet: CosmicHierarchy.Planet) {
        guard activePlanetID != planet.id else { return }
        if cameraTargetPlanetID != planet.id {
            let currentDistance = cameraDistance
            universeZoomBeforeEntry = zoom
            surfaceEntryCameraDistance = currentDistance
        }
        cameraTargetPlanetID = planet.id
        activePlanetID = planet.id
        planetFocusProgress = 0
        surfaceZoom = 1
    }

    private func centerCamera(on planet: CosmicHierarchy.Planet) {
        if cameraTargetPlanetID != planet.id {
            let currentDistance = cameraDistance
            activePlanetID = nil
            universeZoomBeforeEntry = zoom
            surfaceEntryCameraDistance = currentDistance
            cameraTargetPlanetID = planet.id
        }
        if viewportSize.width > 0, isPlanetInteractive(planet) {
            activatePlanetSurface(planet)
        }
        let world = planetWorldPosition(planet)
        animateUniverseCamera(to: CGPoint(x: world.x, y: world.y), zoom: zoom, duration: 0.65)
    }

    /// Canvas does not interpolate captured camera state through
    /// `withAnimation`. Advance the one universe camera explicitly so the
    /// backdrop, stars, orbits, planets and map surface all move together.
    private func animateUniverseCamera(to targetCamera: CGPoint,
                                       zoom targetZoom: CGFloat,
                                       duration: Double,
                                       completion: (() -> Void)? = nil) {
        let token = UUID()
        cameraAnimationToken = token
        let startCamera = camera
        let startZoom = zoom
        let frameCount = max(1, Int(duration * 60))
        Task { @MainActor in
            for frame in 1...frameCount {
                guard cameraAnimationToken == token else { return }
                let linear = CGFloat(frame) / CGFloat(frameCount)
                let progress = linear * linear * (3 - 2 * linear)
                camera = CGPoint(
                    x: startCamera.x + (targetCamera.x - startCamera.x) * progress,
                    y: startCamera.y + (targetCamera.y - startCamera.y) * progress
                )
                zoom = startZoom + (targetZoom - startZoom) * progress
                if frame < frameCount {
                    try? await Task.sleep(for: .milliseconds(16))
                }
            }
            guard cameraAnimationToken == token else { return }
            completion?()
        }
    }

    private func centerInitialCameraIfNeeded(size: CGSize) {
        guard !didCenterInitialCamera, !hierarchy.planets.isEmpty else { return }
        let overview = universeOverview(size: size)
        camera = overview.camera
        zoom = overview.zoom
        didCenterInitialCamera = true
    }

    /// Fits every semantic planet into the usable viewport. The initial view
    /// is therefore derived from the actual universe bounds instead of a fixed
    /// zoom value that could show only one star system.
    private func universeOverview(size: CGSize) -> (camera: CGPoint, zoom: CGFloat) {
        let worlds = hierarchy.planets.map(planetWorldPosition)
        guard !worlds.isEmpty, size.width > 0, size.height > 0 else {
            return (.zero, 0.75)
        }
        let minX = worlds.map(\.x).min() ?? 0
        let maxX = worlds.map(\.x).max() ?? 0
        let minY = worlds.map(\.y).min() ?? 0
        let maxY = worlds.map(\.y).max() ?? 0
        let overviewCamera = CGPoint(
            x: (minX + maxX) / 2,
            y: (minY + maxY) / 2
        )
        guard hierarchy.planets.count > 1 else { return (overviewCamera, 0.75) }

        let focalLength = min(size.width, size.height) * 1.15
        let visibleBounds = CGRect(x: 24, y: 88,
                                   width: max(1, size.width - 48),
                                   height: max(1, size.height - 188))
        func fits(_ candidateZoom: CGFloat) -> Bool {
            let distance = universeCameraDistance(for: candidateZoom)
            return hierarchy.planets.allSatisfy { planet in
                let world = planetWorldPosition(planet)
                let depth = max(0.35, distance - world.z)
                let scale = focalLength / depth
                let center = CGPoint(
                    x: size.width / 2 + (world.x - overviewCamera.x) * scale,
                    y: size.height / 2 - (world.y - overviewCamera.y) * scale
                )
                let radius = max(1, planetWorldRadius(planet) * scale) + 20
                return visibleBounds.contains(CGPoint(x: center.x - radius, y: center.y - radius))
                    && visibleBounds.contains(CGPoint(x: center.x + radius, y: center.y + radius))
            }
        }

        var lower = minimumZoom
        var upper: CGFloat = 0.75
        for _ in 0..<48 {
            let candidate = (lower + upper) / 2
            if fits(candidate) { lower = candidate } else { upper = candidate }
        }
        return (overviewCamera, max(minimumZoom, lower * 0.9))
    }

    private func activateCenteredSurfaceIfNeeded() {
        guard activePlanetID == nil, viewportSize.width > 0,
              let planetID = detailedPlanetID(for: viewportSize),
              let planet = hierarchy.planets.first(where: { $0.id == planetID }),
              isPlanetInteractive(planet) else { return }
        activatePlanetSurface(planet)
    }

    /// Preserve the original globe interaction and administrative rendering,
    /// while limiting its data to the selected semantic planet.
    private func planetLayout(_ planet: CosmicHierarchy.Planet) -> StarLayout {
        cachedPlanetLayouts[planet.id]
            ?? StarLayout(nodes: [], links: [], embeddingCount: 0)
    }

    private var levelTitle: String {
        if zoom < 1.6 { return "恒星系视图" }
        return "行星与卫星"
    }

    private var levelIcon: String {
        zoom < 1.6 ? "hurricane" : "globe.americas.fill"
    }

    private func draw(context: inout GraphicsContext, size: CGSize) {
        drawBackdrop(context: &context, size: size)
        // Cross-fade the hierarchy instead of replacing one canvas at a hard
        // zoom threshold. This makes a star system visibly unfold from its
        // galaxy while the user pinches.
        if zoom < 2.0 {
            var galaxyLayer = context
            galaxyLayer.opacity = Double(min(1, max(0, (2.0 - zoom) / 0.8)))
            drawGalaxies(context: &galaxyLayer, size: size)
        }
        var systemLayer = context
        systemLayer.opacity = Double(min(1, max(0.72, (zoom - 0.45) / 0.9)))
        drawPlanets(context: &systemLayer, size: size)
    }

    private func drawBackdrop(context: inout GraphicsContext, size: CGSize) {
        for index in 0..<90 {
            let x = CGFloat((index * 73) % 997) / 997 * size.width
            let y = CGFloat((index * 193) % 991) / 991 * size.height
            let radius: CGFloat = index.isMultiple(of: 7) ? 1.3 : 0.7
            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: radius * 2, height: radius * 2)),
                         with: .color(.white.opacity(index.isMultiple(of: 5) ? 0.5 : 0.22)))
        }
    }

    private func drawGalaxies(context: inout GraphicsContext, size: CGSize) {
        for galaxy in hierarchy.galaxies {
            let projection = perspectiveProject(galaxyWorldPosition(galaxy), size: size)
            let center = projection.point
            let radius = max(8, starWorldRadius(galaxy) * projection.pointsPerWorldUnit * 2.4)
            let color = cosmicColor(galaxy.id)
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: rect), with: .radialGradient(
                Gradient(colors: [.white.opacity(0.9), color.opacity(0.8), color.opacity(0.08)]),
                center: center, startRadius: 1, endRadius: radius
            ))
            context.stroke(Path(ellipseIn: rect.insetBy(dx: -7, dy: -7)), with: .color(color.opacity(0.25)), lineWidth: 2)
            context.draw(Text(galaxy.name).font(.caption.bold()).foregroundStyle(.white),
                         at: CGPoint(x: center.x, y: center.y + radius + 13), anchor: .center)
            context.draw(Text("\(galaxy.planetIDs.count) 个星球").font(.caption2).foregroundStyle(.white.opacity(0.62)),
                         at: CGPoint(x: center.x, y: center.y + radius + 28), anchor: .center)
        }
    }

    private func drawPlanets(context: inout GraphicsContext, size: CGSize) {
        for galaxy in hierarchy.galaxies {
            let starProjection = perspectiveProject(galaxyWorldPosition(galaxy), size: size)
            let galaxyCenter = starProjection.point
            let starRadius = max(5, starWorldRadius(galaxy) * starProjection.pointsPerWorldUnit)
            let starRect = CGRect(x: galaxyCenter.x - starRadius, y: galaxyCenter.y - starRadius,
                                  width: starRadius * 2, height: starRadius * 2)
            context.fill(Path(ellipseIn: starRect), with: .radialGradient(
                Gradient(colors: [.white, .yellow, .orange.opacity(0.25)]),
                center: galaxyCenter, startRadius: 1, endRadius: starRadius * 1.7
            ))
            context.draw(Text(galaxy.name.replacingOccurrences(of: "星系", with: "恒星"))
                .font(.caption2.bold()).foregroundStyle(.yellow.opacity(0.9)),
                         at: CGPoint(x: galaxyCenter.x, y: galaxyCenter.y + starRadius + 12), anchor: .center)

            let members = galaxy.planetIDs
            for orbit in members.indices {
                var path = Path()
                let orbitSegments = zoom < 1.6 ? 24 : 36
                for step in 0...orbitSegments {
                    let angle = CGFloat(step) / CGFloat(orbitSegments) * 2 * .pi
                    let point = perspectiveProject(
                        orbitWorldPosition(galaxy: galaxy, orbit: orbit, angle: angle), size: size
                    ).point
                    step == 0 ? path.move(to: point) : path.addLine(to: point)
                }
                context.stroke(path, with: .color(.white.opacity(0.12)), lineWidth: 0.8)
            }
        }
        for planet in hierarchy.planets.sorted(by: { planetWorldPosition($0).z < planetWorldPosition($1).z }) {
            // Once this planet is large enough for its semantic map, the
            // overlay renders it at this exact camera-projected center/radius.
            // Do not also draw the simplified sphere underneath.
            if planetVisualRadius(planet, size: size) * 2 >= surfaceRevealDiameter(for: size) {
                continue
            }
            let center = planetScreenPosition(planet, size: size)
            let radius = planetVisualRadius(planet, size: size)
            let color = cosmicColor(planet.id + 31)
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: rect), with: .radialGradient(
                Gradient(colors: [.white.opacity(0.85), color.opacity(0.92), color.opacity(0.5)]),
                center: CGPoint(x: center.x - radius * 0.25, y: center.y - radius * 0.25),
                startRadius: 1, endRadius: radius
            ))
            // Distance-based LOD: far planets render no Point-derived land;
            // medium planets sample a handful of regions. Full geography is
            // instantiated only by SemanticGlobe when the planet is near.
            let patchLimit = radius < 18 ? 0 : radius < 38 ? 6 : 18
            if patchLimit > 0 {
                var surface = context
                surface.clip(to: Path(ellipseIn: rect))
                let step = max(1, planet.nodeIndices.count / patchLimit)
                for index in planet.nodeIndices.enumerated().compactMap({ $0.offset.isMultiple(of: step) ? $0.element : nil }).prefix(patchLimit) {
                    let local = geographicSurfacePoint(index: index, center: center, radius: radius)
                    let patch = max(1.5, radius * 0.16)
                    surface.fill(Path(ellipseIn: CGRect(x: local.x - patch, y: local.y - patch * 0.65,
                                                         width: patch * 2, height: patch * 1.3)),
                                 with: .color(cosmicColor(index + planet.id * 13).opacity(0.34)))
                }
            }
            if radius >= 11 {
                context.draw(Text(planet.name).font(.caption2.bold()).foregroundStyle(.white),
                             at: CGPoint(x: center.x, y: center.y + radius + 11), anchor: .center)
            }

            // Satellites summarize the next semantic level. They are visual
            // children of the planet, not individual Points.
            let moonCount = radius >= 16 ? min(5, max(1, Int(ceil(sqrt(Double(planet.nodeIndices.count) / 6))))) : 0
            let moonOrbit = radius + 13
            context.stroke(Path(ellipseIn: CGRect(x: center.x - moonOrbit, y: center.y - moonOrbit * 0.38,
                                                   width: moonOrbit * 2, height: moonOrbit * 0.76)),
                           with: .color(.white.opacity(0.16)), lineWidth: 0.6)
            for moon in 0..<moonCount {
                let angle = CGFloat(moon) / CGFloat(moonCount) * 2 * .pi + CGFloat(planet.id) * 0.71
                let moonCenter = CGPoint(x: center.x + cos(angle) * moonOrbit,
                                         y: center.y + sin(angle) * moonOrbit * 0.38)
                let moonRadius: CGFloat = moon == 0 ? 3.2 : 2.4
                context.fill(Path(ellipseIn: CGRect(x: moonCenter.x - moonRadius, y: moonCenter.y - moonRadius,
                                                     width: moonRadius * 2, height: moonRadius * 2)),
                             with: .color(.white.opacity(0.72)))
            }
        }
    }

    private func planetVisualRadius(_ planet: CosmicHierarchy.Planet, size: CGSize) -> CGFloat {
        let projection = perspectiveProject(planetWorldPosition(planet), size: size)
        return max(0.25, planetWorldRadius(planet) * projection.pointsPerWorldUnit)
    }

    private func preparesDetailedRenderer(_ planet: CosmicHierarchy.Planet, size: CGSize) -> Bool {
        // Preload well before the visible handoff. Its frame already follows
        // the universe projection, so there is no planet-local entrance scale.
        planetVisualRadius(planet, size: size) * 2 >= surfaceRevealDiameter(for: size) * 0.72
    }

    private func isPlanetOnScreen(_ planet: CosmicHierarchy.Planet, size: CGSize) -> Bool {
        let center = planetScreenPosition(planet, size: size)
        let radius = planetVisualRadius(planet, size: size)
        return CGRect(origin: .zero, size: size).insetBy(dx: -radius, dy: -radius).contains(center)
    }

    private func detailedPlanetID(for size: CGSize) -> Int? {
        if let activePlanetID { return activePlanetID }
        if let cameraTargetPlanetID { return cameraTargetPlanetID }
        let screenCenter = CGPoint(x: size.width / 2, y: size.height / 2)
        return hierarchy.planets
            .filter { planetVisualRadius($0, size: size) * 2 >= surfaceRevealDiameter(for: size) * 0.72 }
            .min {
                distance(planetScreenPosition($0, size: size), screenCenter)
                    < distance(planetScreenPosition($1, size: size), screenCenter)
            }?.id
    }

    private func isPlanetInteractive(_ planet: CosmicHierarchy.Planet) -> Bool {
        guard viewportSize.width > 0 else { return false }
        return planetVisualRadius(planet, size: viewportSize) * 2 >= surfaceRevealDiameter(for: viewportSize)
    }

    private func surfaceRevealDiameter(for size: CGSize) -> CGFloat {
        // Reveal the spherical terrain while the planet is still part of the
        // wider universe—about one quarter of the shorter screen dimension.
        max(84, min(size.width, size.height) * 0.26)
    }

    private func fittedPlanetDiameter(for size: CGSize) -> CGFloat {
        // Match the standalone globe's useful viewport: leave room for the
        // title and controls while fitting the planet as large as possible.
        min(size.width * 0.86, max(220, size.height - 190) * 0.86)
    }

    private func maximumSafeDiameter(for size: CGSize) -> CGFloat {
        // Effectively unlimited for interaction; this only keeps SwiftUI frame
        // arithmetic finite under an accidental extreme gesture value.
        max(size.width, size.height) * 1_000_000
    }

    private func zoom(forPlanetDiameter diameter: CGFloat,
                      planet: CosmicHierarchy.Planet,
                      size: CGSize) -> CGFloat {
        let focalLength = min(size.width, size.height) * 1.15
        let worldDiameter = planetWorldRadius(planet) * 2
        let planetDepth = planetWorldPosition(planet).z
        let entryDistance = surfaceEntryCameraDistance > 0
            ? surfaceEntryCameraDistance
            : universeCameraDistance(for: universeZoomBeforeEntry)
        let entryGap = max(0.35, entryDistance - planetDepth)
        let targetGap = max(0.000001, worldDiameter * focalLength / max(0.000001, diameter))
        let mapScale = pow(entryGap / targetGap, 1 / 0.72)
        return min(maximumZoom, max(minimumZoom, universeZoomBeforeEntry * mapScale))
    }

    private func geographicSurfacePoint(index: Int, center: CGPoint, radius: CGFloat) -> CGPoint {
        guard let geography = geographies[layout.nodes[index].point.id] else { return center }
        let latitude = CGFloat(geography.latitude) * .pi / 180
        let longitude = CGFloat(geography.longitude) * .pi / 180
        return CGPoint(x: center.x + sin(longitude) * cos(latitude) * radius * 0.82,
                       y: center.y - sin(latitude) * radius * 0.82)
    }

    private func planetScreenPosition(_ planet: CosmicHierarchy.Planet, size: CGSize) -> CGPoint {
        perspectiveProject(planetWorldPosition(planet), size: size).point
    }

    private func galaxyWorldPosition(_ galaxy: CosmicHierarchy.Galaxy) -> Point3D {
        Point3D(x: galaxy.center.x * 22, y: galaxy.center.y * 22, z: galaxy.center.z * 10)
    }

    private func orbitWorldPosition(galaxy: CosmicHierarchy.Galaxy, orbit: Int, angle: CGFloat) -> Point3D {
        let star = galaxyWorldPosition(galaxy)
        let radius = 3.2 + CGFloat(orbit) * 2.45
        let inclination = (CGFloat((galaxy.id * 37 + orbit * 19) % 29) / 29 - 0.5) * 0.7
        return Point3D(x: star.x + cos(angle) * radius,
                       y: star.y + sin(angle) * radius * cos(inclination),
                       z: star.z + sin(angle) * radius * sin(inclination))
    }

    private func planetWorldPosition(_ planet: CosmicHierarchy.Planet) -> Point3D {
        guard let galaxy = hierarchy.galaxies.first(where: { $0.id == planet.galaxyID }),
              let orbit = galaxy.planetIDs.firstIndex(of: planet.id) else { return planet.center }
        let dx = planet.center.x - galaxy.center.x, dy = planet.center.y - galaxy.center.y
        let angle = abs(dx) + abs(dy) > 0.0001 ? atan2(dy, dx) : CGFloat(planet.id) * 2.399963
        return orbitWorldPosition(galaxy: galaxy, orbit: orbit, angle: angle)
    }

    private func planetWorldRadius(_ planet: CosmicHierarchy.Planet) -> CGFloat {
        min(1.18, 0.48 + sqrt(CGFloat(planet.nodeIndices.count)) * 0.035)
    }

    private func starWorldRadius(_ galaxy: CosmicHierarchy.Galaxy) -> CGFloat {
        min(1.65, 0.8 + sqrt(CGFloat(galaxy.nodeIndices.count)) * 0.025)
    }

    private var cameraDistance: CGFloat {
        cameraDistance(for: zoom, dollyPlanet: cameraDollyPlanet)
    }

    private func cameraDistance(for targetZoom: CGFloat,
                                dollyPlanet planet: CosmicHierarchy.Planet?) -> CGFloat {
        guard let planet else { return universeCameraDistance(for: targetZoom) }
        // Continue dollying toward the selected planet itself. The old curve
        // approached a fixed universe-space Z=5 plane, which imposed a hard
        // visual magnification ceiling for planets farther away in depth.
        let planetDepth = planetWorldPosition(planet).z
        let entryDistance = surfaceEntryCameraDistance > 0
            ? surfaceEntryCameraDistance
            : universeCameraDistance(for: universeZoomBeforeEntry)
        let entryGap = max(0.35, entryDistance - planetDepth)
        let mapScale = max(0.000001, targetZoom / max(minimumZoom, universeZoomBeforeEntry))
        return planetDepth + max(0.000001, entryGap / pow(mapScale, 0.72))
    }

    private func universeCameraDistance(for zoom: CGFloat) -> CGFloat {
        // Approach the actual front of this universe rather than a hard-coded
        // Z=5 plane. The former constant produced a singularity where zoom
        // jumped into the tens of millions and then stopped changing visually.
        universeCameraNearDistance + 58 / pow(max(minimumZoom, zoom), 0.72)
    }

    private func universeZoom(forCameraDistance distance: CGFloat) -> CGFloat {
        let near = universeCameraNearDistance
        let safeDistance = max(near + 0.000001, distance)
        let solved = pow(58 / (safeDistance - near), 1 / 0.72)
        return min(maximumZoom, max(minimumZoom, solved))
    }

    private var universeCameraNearDistance: CGFloat {
        let planetFront = hierarchy.planets.map { planetWorldPosition($0).z }.max() ?? 0
        let galaxyFront = hierarchy.galaxies.map { galaxyWorldPosition($0).z }.max() ?? 0
        return max(planetFront, galaxyFront) + 0.000001
    }

    private func perspectiveProject(_ world: Point3D, size: CGSize)
    -> (point: CGPoint, depth: CGFloat, pointsPerWorldUnit: CGFloat) {
        let focalLength = min(size.width, size.height) * 1.15
        let depth = max(0.000001, cameraDistance - world.z)
        let scale = focalLength / depth
        return (CGPoint(x: size.width / 2 + (world.x - camera.x) * scale,
                        y: size.height / 2 - (world.y - camera.y) * scale), depth, scale)
    }

    private func drawPoints(context: inout GraphicsContext, size: CGSize) {
        guard let planet = activePlanet ?? nearestPlanetToCamera() else { return }
        let map = planetMapGeometry(planet: planet, size: size)
        let globeRect = CGRect(x: map.center.x - map.radius, y: map.center.y - map.radius,
                               width: map.radius * 2, height: map.radius * 2)
        context.fill(Path(ellipseIn: globeRect), with: .radialGradient(
            Gradient(colors: [cosmicColor(planet.id + 31).opacity(0.62), .blue.opacity(0.28), .black.opacity(0.9)]),
            center: CGPoint(x: map.center.x - map.radius * 0.3, y: map.center.y - map.radius * 0.32),
            startRadius: 2, endRadius: map.radius * 1.25
        ))
        context.stroke(Path(ellipseIn: globeRect), with: .color(.cyan.opacity(0.55)), lineWidth: 2)

        var surface = context
        surface.clip(to: Path(ellipseIn: globeRect))
        drawSphereGrid(context: &surface, map: map)

        for index in planet.nodeIndices {
            let projected = planetMapProjection(index: index, map: map, planet: planet)
            guard projected.depth >= 0 else { continue }
            let point = projected.point
            let regionRadius: CGFloat = max(2, map.radius * (0.045 + CGFloat((index * 17) % 4) * 0.006))
            surface.fill(Path(ellipseIn: CGRect(x: point.x - regionRadius, y: point.y - regionRadius * 0.65,
                                                 width: regionRadius * 2, height: regionRadius * 1.3)),
                         with: .color(cosmicColor(index + planet.id * 13).opacity(0.1)))
        }

        for link in layout.links where planet.nodeIndices.contains(link.a) && planet.nodeIndices.contains(link.b) {
            let a = planetMapProjection(index: link.a, map: map, planet: planet)
            let b = planetMapProjection(index: link.b, map: map, planet: planet)
            guard a.depth >= 0, b.depth >= 0 else { continue }
            var path = Path()
            path.move(to: a.point)
            path.addLine(to: b.point)
            surface.stroke(path, with: .color(.cyan.opacity(0.3 + Double(link.strength) * 0.42)),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [5, 4]))
        }
        for index in planet.nodeIndices {
            let node = layout.nodes[index]
            let projected = planetMapProjection(index: index, map: map, planet: planet)
            guard projected.depth >= 0 else { continue }
            let center = projected.point
            let color = cosmicColor(index + planet.id * 13)
            let radius: CGFloat = focusedPointID == node.point.id ? 8 : 5.5
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            surface.fill(Path(ellipseIn: rect), with: .color(color))
            if focusedPointID == node.point.id {
                surface.stroke(Path(ellipseIn: rect.insetBy(dx: -8, dy: -8)), with: .color(.yellow), lineWidth: 3)
            }
            let labelStride: Int = zoom >= 40 ? 1 : zoom >= 20 ? 2 : zoom >= 10 ? 5 : .max
            if labelStride != .max, index.isMultiple(of: labelStride) {
                surface.draw(Text(String(node.point.title.prefix(24))).font(.caption2).foregroundStyle(.white.opacity(0.88)),
                             at: CGPoint(x: center.x, y: center.y + radius + 11), anchor: .center)
            }
        }
        context.draw(Text(planet.name).font(.headline.bold()).foregroundStyle(.white),
                     at: CGPoint(x: map.center.x, y: map.center.y - map.radius - 18), anchor: .center)
    }

    private var activePlanet: CosmicHierarchy.Planet? {
        guard let activePlanetID else { return nil }
        return hierarchy.planets.first { $0.id == activePlanetID }
    }

    private var cameraDollyPlanet: CosmicHierarchy.Planet? {
        if let activePlanet { return activePlanet }
        guard let cameraTargetPlanetID else { return nil }
        return hierarchy.planets.first { $0.id == cameraTargetPlanetID }
    }

    private func nearestPlanetToCamera() -> CosmicHierarchy.Planet? {
        hierarchy.planets.min {
            hypot($0.center.x - camera.x, $0.center.y - camera.y)
                < hypot($1.center.x - camera.x, $1.center.y - camera.y)
        }
    }

    private func planetMapGeometry(planet: CosmicHierarchy.Planet, size: CGSize) -> (center: CGPoint, radius: CGFloat, extent: CGFloat) {
        let sourceCenter = planetScreenPosition(planet, size: size)
        let targetCenter = CGPoint(x: size.width / 2, y: size.height / 2 + 4)
        let sourceRadius = planetVisualRadius(planet, size: size)
        let baseTargetRadius = min(size.width * 0.43, max(120, (size.height - 190) * 0.43))
        let entryZoom = max(1, universeZoomBeforeEntry + 4.2)
        let surfaceScale = activePlanetID == nil ? 1 : max(1, zoom / entryZoom)
        let targetRadius = baseTargetRadius * surfaceScale
        let radius = sourceRadius + (targetRadius - sourceRadius) * planetFocusProgress
        let mapCenter = CGPoint(x: sourceCenter.x + (targetCenter.x - sourceCenter.x) * planetFocusProgress,
                                y: sourceCenter.y + (targetCenter.y - sourceCenter.y) * planetFocusProgress)
        let extent = max(0.35, planet.nodeIndices.reduce(CGFloat(0)) { partial, index in
            let point = layout.nodes[index].position
            return max(partial, hypot(point.x - planet.center.x, point.y - planet.center.y))
        })
        return (mapCenter, radius, extent)
    }

    private func planetMapProjection(index: Int,
                                     map: (center: CGPoint, radius: CGFloat, extent: CGFloat),
                                     planet: CosmicHierarchy.Planet) -> (point: CGPoint, depth: CGFloat) {
        if let geography = geographies[layout.nodes[index].point.id] {
            return sphereProjection(latitude: CGFloat(geography.latitude) * .pi / 180,
                                    longitude: CGFloat(geography.longitude) * .pi / 180,
                                    center: map.center, radius: map.radius)
        }
        let position = layout.nodes[index].position
        let latitude = max(-CGFloat.pi / 2, min(.pi / 2, (position.y - planet.center.y) / map.extent))
        let longitude = max(-CGFloat.pi, min(.pi, (position.x - planet.center.x) / map.extent))
        return sphereProjection(latitude: latitude, longitude: longitude, center: map.center, radius: map.radius)
    }

    private func sphereProjection(latitude: CGFloat, longitude: CGFloat,
                                  center: CGPoint, radius: CGFloat) -> (point: CGPoint, depth: CGFloat) {
        let x = cos(latitude) * sin(longitude)
        let y = sin(latitude)
        let z = cos(latitude) * cos(longitude)
        let yawX = cos(planetYaw) * x + sin(planetYaw) * z
        let yawZ = -sin(planetYaw) * x + cos(planetYaw) * z
        let pitchY = cos(planetPitch) * y - sin(planetPitch) * yawZ
        let pitchZ = sin(planetPitch) * y + cos(planetPitch) * yawZ
        return (CGPoint(x: center.x + yawX * radius, y: center.y - pitchY * radius), pitchZ)
    }

    private func drawSphereGrid(context: inout GraphicsContext,
                                map: (center: CGPoint, radius: CGFloat, extent: CGFloat)) {
        for latitudeDegrees in stride(from: -60, through: 60, by: 30) {
            var path = Path(); var drawing = false
            for longitudeDegrees in stride(from: -180, through: 180, by: 6) {
                let p = sphereProjection(latitude: CGFloat(latitudeDegrees) * .pi / 180,
                                         longitude: CGFloat(longitudeDegrees) * .pi / 180,
                                         center: map.center, radius: map.radius)
                if p.depth >= 0 { drawing ? path.addLine(to: p.point) : path.move(to: p.point); drawing = true }
                else { drawing = false }
            }
            context.stroke(path, with: .color(.cyan.opacity(0.16)), lineWidth: 0.8)
        }
        for longitudeDegrees in stride(from: -150, through: 180, by: 30) {
            var path = Path(); var drawing = false
            for latitudeDegrees in stride(from: -90, through: 90, by: 4) {
                let p = sphereProjection(latitude: CGFloat(latitudeDegrees) * .pi / 180,
                                         longitude: CGFloat(longitudeDegrees) * .pi / 180,
                                         center: map.center, radius: map.radius)
                if p.depth >= 0 { drawing ? path.addLine(to: p.point) : path.move(to: p.point); drawing = true }
                else { drawing = false }
            }
            context.stroke(path, with: .color(.cyan.opacity(0.14)), lineWidth: 0.8)
        }
    }

    private func screen(_ position: Point3D, size: CGSize) -> CGPoint {
        let scale = min(size.width, size.height) * 0.075 * zoom
        return CGPoint(x: size.width / 2 + (position.x - camera.x) * scale,
                       y: size.height / 2 - (position.y - camera.y) * scale)
    }

    private func panGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                if surfacePlanet(at: value.startLocation, size: size) != nil {
                    // A detailed globe owns this gesture and rotates around
                    // its own projected center.
                    return
                }
                // A drag that begins outside every detailed globe pans the
                // entire universe, even when one planet is currently active.
                if dragOrigin == nil {
                    cameraAnimationToken = UUID()
                    dragOrigin = camera
                }
                // Convert screen translation with the projection scale at the
                // current dolly target. At close range the former far-camera
                // scale turned a few points of dragging into a huge world-space
                // jump, which made the last visible planet disappear.
                let scale: CGFloat
                if let target = cameraDollyPlanet {
                    scale = max(1, perspectiveProject(planetWorldPosition(target), size: size).pointsPerWorldUnit)
                } else {
                    let focalLength = min(size.width, size.height) * 1.15
                    scale = max(1, focalLength / max(0.35, cameraDistance))
                }
                camera = CGPoint(x: (dragOrigin ?? camera).x - value.translation.width / scale,
                                 y: (dragOrigin ?? camera).y + value.translation.height / scale)
            }
            .onEnded { _ in dragOrigin = nil; surfaceRotationOrigin = nil }
    }

    private func surfacePlanet(at location: CGPoint, size: CGSize) -> CosmicHierarchy.Planet? {
        hierarchy.planets
            .filter { planetVisualRadius($0, size: size) * 2 >= surfaceRevealDiameter(for: size) }
            .sorted { planetWorldPosition($0).z > planetWorldPosition($1).z }
            .first { planet in
                distance(planetScreenPosition(planet, size: size), location)
                    <= planetVisualRadius(planet, size: size)
            }
    }

    private func zoomGesture(size: CGSize) -> some Gesture {
        MagnifyGesture(minimumScaleDelta: 0)
            .onChanged { value in
                if zoomOrigin == nil {
                    cameraAnimationToken = UUID()
                    zoomOrigin = zoom
                    cameraMagnificationDistanceOrigin = cameraDistance
                    let anchor = CGPoint(
                        x: value.startAnchor.x * size.width,
                        y: value.startAnchor.y * size.height
                    )
                    if let planet = zoomTargetPlanet(at: anchor, size: size) {
                        beginDollyTowardPlanet(planet)
                        magnificationPlanetID = planet.id
                        magnificationPlanetScreenAnchor = planetScreenPosition(planet, size: size)
                        cameraMagnificationDistanceOrigin = cameraDistance
                        cameraMagnificationDiameterOrigin = planetVisualRadius(planet, size: size) * 2
                    } else if let planet = cameraDollyPlanet,
                              isPlanetOnScreen(planet, size: size) {
                        magnificationPlanetID = planet.id
                        magnificationPlanetScreenAnchor = planetScreenPosition(planet, size: size)
                        cameraMagnificationDiameterOrigin = planetVisualRadius(planet, size: size) * 2
                    } else {
                        // A stale off-screen planet must not capture a new
                        // universe pinch.
                        cameraTargetPlanetID = nil
                        magnificationPlanetID = nil
                    }
                }
                let gesturePlanet = magnificationPlanetID.flatMap { id in
                    hierarchy.planets.first { $0.id == id }
                }
                if let planet = gesturePlanet,
                   let diameterOrigin = cameraMagnificationDiameterOrigin {
                    let targetDiameter = min(
                        maximumSafeDiameter(for: size),
                        max(0.1, diameterOrigin * max(0.0001, value.magnification))
                    )
                    zoom = zoom(forPlanetDiameter: targetDiameter, planet: planet, size: size)
                    if let anchor = magnificationPlanetScreenAnchor {
                        camera = cameraKeepingPlanet(planet, at: anchor, zoom: zoom, size: size)
                    }
                } else {
                    let originDistance = cameraMagnificationDistanceOrigin ?? cameraDistance
                    let near = universeCameraNearDistance
                    let targetDistance = near + (originDistance - near) / max(0.0001, value.magnification)
                    zoom = universeZoom(forCameraDistance: targetDistance)
                }
                if activePlanetID != nil {
                    planetFocusProgress = min(1, max(0, (zoom - universeZoomBeforeEntry) / 4.2))
                }
            }
            .onEnded { value in
                // A planet-relative camera can move behind the universe's
                // front-most Z plane when the chosen system sits farther
                // away. Converting it back to the whole-universe curve after
                // a zoom-in cannot preserve that distance and looks like a
                // spring-back. Keep the chosen target after enlargement;
                // only release it while the user is deliberately zooming out.
                let wasZoomingOut = value.magnification < 1
                zoomOrigin = nil
                cameraMagnificationDiameterOrigin = nil
                cameraMagnificationDistanceOrigin = nil
                magnificationPlanetID = nil
                magnificationPlanetScreenAnchor = nil
                if let planet = activePlanet,
                   planetVisualRadius(planet, size: size) * 2 < surfaceRevealDiameter(for: size) {
                    deactivatePlanetSurfaceKeepingCameraTarget()
                    if wasZoomingOut {
                        releasePlanetCameraIfFarEnough(planet, size: size)
                    }
                    return
                }
                if wasZoomingOut, let planet = cameraDollyPlanet {
                    releasePlanetCameraIfFarEnough(planet, size: size)
                }
                if activePlanetID == nil { activateCenteredSurfaceIfNeeded() }
            }
    }

    /// Picks the planet beneath the initial pinch centroid. A generous minimum
    /// hit radius makes small/far planets selectable without first centering
    /// them, while still leaving empty space for whole-universe zoom.
    private func zoomTargetPlanet(at location: CGPoint, size: CGSize) -> CosmicHierarchy.Planet? {
        hierarchy.planets
            .filter { isPlanetOnScreen($0, size: size) }
            .sorted { planetWorldPosition($0).z > planetWorldPosition($1).z }
            .first { planet in
                let radius = max(44, planetVisualRadius(planet, size: size) + 20)
                return distance(planetScreenPosition(planet, size: size), location) <= radius
            }
    }

    private func beginDollyTowardPlanet(_ planet: CosmicHierarchy.Planet) {
        guard cameraTargetPlanetID != planet.id else { return }
        let currentDistance = cameraDistance
        universeZoomBeforeEntry = zoom
        surfaceEntryCameraDistance = currentDistance
        cameraTargetPlanetID = planet.id
    }

    private func cameraKeepingPlanet(_ planet: CosmicHierarchy.Planet,
                                     at screenPoint: CGPoint,
                                     zoom targetZoom: CGFloat,
                                     size: CGSize) -> CGPoint {
        let world = planetWorldPosition(planet)
        let distance = cameraDistance(for: targetZoom, dollyPlanet: planet)
        let focalLength = min(size.width, size.height) * 1.15
        let scale = focalLength / max(0.35, distance - world.z)
        return CGPoint(
            x: world.x - (screenPoint.x - size.width / 2) / scale,
            y: world.y + (screenPoint.y - size.height / 2) / scale
        )
    }

    private func changeZoom(_ factor: CGFloat) {
        var mapPlanet = cameraDollyPlanet
        if mapPlanet == nil, viewportSize.width > 0,
           let planetID = detailedPlanetID(for: viewportSize),
           let candidate = hierarchy.planets.first(where: { $0.id == planetID }),
           isPlanetInteractive(candidate) {
            activatePlanetSurface(candidate)
            mapPlanet = candidate
        }
        if let planet = mapPlanet, viewportSize.width > 0 {
            let currentDiameter = planetVisualRadius(planet, size: viewportSize) * 2
            let screenAnchor = planetScreenPosition(planet, size: viewportSize)
            let step: CGFloat = factor >= 1 ? 1.25 : 0.8
            let targetDiameter = min(
                maximumSafeDiameter(for: viewportSize),
                max(0.1, currentDiameter * step)
            )
            let targetZoom = zoom(forPlanetDiameter: targetDiameter, planet: planet, size: viewportSize)
            let targetCamera = cameraKeepingPlanet(
                planet, at: screenAnchor, zoom: targetZoom, size: viewportSize
            )
            animateUniverseCamera(to: targetCamera, zoom: targetZoom, duration: 0.22) {
                if targetDiameter < surfaceRevealDiameter(for: viewportSize) {
                    deactivatePlanetSurfaceKeepingCameraTarget()
                    releasePlanetCameraIfFarEnough(planet, size: viewportSize)
                }
            }
            return
        }
        let visualStep: CGFloat = factor >= 1 ? 1.25 : 0.8
        let near = universeCameraNearDistance
        let targetDistance = near + (cameraDistance - near) / visualStep
        let targetZoom = universeZoom(forCameraDistance: targetDistance)
        animateUniverseCamera(to: camera, zoom: targetZoom, duration: 0.25) {
            activateCenteredSurfaceIfNeeded()
        }
    }

    private func universeControl(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName).foregroundStyle(.white)
                .frame(width: 34, height: 34).background(.white.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
    }

    private func handleTap(at location: CGPoint, size: CGSize) {
        if let tappedPlanet = planetHit(at: location, size: size),
           tappedPlanet.id != activePlanetID {
            centerCamera(on: tappedPlanet)
            return
        }
        if let planet = activePlanet {
            let map = planetMapGeometry(planet: planet, size: size)
            let visible = planet.nodeIndices.filter {
                planetMapProjection(index: $0, map: map, planet: planet).depth >= 0
            }
            if let index = visible.min(by: {
                distance(planetMapProjection(index: $0, map: map, planet: planet).point, location)
                    < distance(planetMapProjection(index: $1, map: map, planet: planet).point, location)
            }), distance(planetMapProjection(index: index, map: map, planet: planet).point, location) < 34 {
                focusedPointID = layout.nodes[index].point.id
                onSelect(layout.nodes[index].point)
            }
        } else if let planet = hierarchy.planets.min(by: {
            distance(planetScreenPosition($0, size: size), location)
                < distance(planetScreenPosition($1, size: size), location)
        }).flatMap({ planet in
            let hitRadius = max(18, planetVisualRadius(planet, size: size) + 10)
            return distance(planetScreenPosition(planet, size: size), location) <= hitRadius ? planet : nil
        }) {
            // A planet tap is selection/centering only. It must never be
            // mistaken for its parent galaxy's zoom action.
            if planetVisualRadius(planet, size: size) * 2 >= surfaceRevealDiameter(for: size) {
                activatePlanetSurface(planet)
            }
            centerCamera(on: planet)
        } else if zoom < 1.6, let galaxy = hierarchy.galaxies.min(by: {
            distance(perspectiveProject(galaxyWorldPosition($0), size: size).point, location)
                < distance(perspectiveProject(galaxyWorldPosition($1), size: size).point, location)
        }).flatMap({ distance(perspectiveProject(galaxyWorldPosition($0), size: size).point, location) < 80 ? $0 : nil }) {
            let world = galaxyWorldPosition(galaxy)
            animateUniverseCamera(to: CGPoint(x: world.x, y: world.y), zoom: 2.2, duration: 0.45)
        }
    }

    private func planetHit(at location: CGPoint, size: CGSize) -> CosmicHierarchy.Planet? {
        hierarchy.planets.min(by: {
            distance(planetScreenPosition($0, size: size), location)
                < distance(planetScreenPosition($1, size: size), location)
        }).flatMap { planet in
            let hitRadius = max(18, planetVisualRadius(planet, size: size) + 10)
            return distance(planetScreenPosition(planet, size: size), location) <= hitRadius
                ? planet : nil
        }
    }

    private func nearest<T>(_ values: [T], to location: CGPoint, size: CGSize,
                            center: KeyPath<T, Point3D>) -> T? {
        values.min {
            distance(screen($0[keyPath: center], size: size), location)
                < distance(screen($1[keyPath: center], size: size), location)
        }.flatMap { distance(screen($0[keyPath: center], size: size), location) < 80 ? $0 : nil }
    }

    private func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat { hypot(lhs.x - rhs.x, lhs.y - rhs.y) }

    private func focus(on request: PointMapFocusRequest?) {
        guard let request,
              let index = layout.nodes.firstIndex(where: { $0.point.id == request.pointID }) else { return }
        let currentCameraDistance = cameraDistance
        focusedPointID = request.pointID
        let planetID = hierarchy.nodeToPlanet[index]
        universeZoomBeforeEntry = max(1.8, min(3.2, zoom))
        surfaceEntryCameraDistance = currentCameraDistance
        cameraTargetPlanetID = planetID
        activePlanetID = planetID
        if let planetID, let planet = hierarchy.planets.first(where: { $0.id == planetID }) {
            let world = planetWorldPosition(planet)
            animateUniverseCamera(
                to: CGPoint(x: world.x, y: world.y),
                zoom: max(zoom, 24),
                duration: 0.55
            ) {
                planetFocusProgress = 1
            }
        } else {
            planetFocusProgress = 1
        }
    }

    private func cosmicColor(_ seed: Int) -> Color {
        Color(hue: Double(abs(seed * 47) % 360) / 360, saturation: 0.78, brightness: 0.98)
    }
}

private struct CosmicHierarchy {
    struct Galaxy {
        let id: Int
        let name: String
        let nodeIndices: [Int]
        let planetIDs: [Int]
        let center: Point3D
    }
    struct Planet {
        let id: Int
        let galaxyID: Int
        let name: String
        let nodeIndices: [Int]
        let center: Point3D
    }
    let galaxies: [Galaxy]
    let planets: [Planet]
    let nodeToPlanet: [Int: Int]

    static func make(layout: StarLayout, geographies: [PointID: PointGeographyRecord] = [:]) -> Self {
        guard !layout.nodes.isEmpty else { return Self(galaxies: [], planets: [], nodeToPlanet: [:]) }
        _ = geographies // Geography still drives the map inside each planet.

        // Universe bodies are deliberately much coarser than administrative
        // regions. Aim for tens of Points per planet and cap the total so that
        // sparse/outlier Points can never become one-Point planets.
        let desiredPlanetCount = min(10, max(1, Int((sqrt(Double(layout.nodes.count) / 8)).rounded())))
        let planetGroups = spatialGroups(
            indices: Array(layout.nodes.indices),
            count: desiredPlanetCount,
            nodes: layout.nodes
        )
        var planets: [Planet] = []
        var nodeToPlanet: [Int: Int] = [:]
        for (id, group) in planetGroups.enumerated() {
            group.forEach { nodeToPlanet[$0] = id }
            planets.append(Planet(id: id, galaxyID: 0,
                                  name: name(for: group, nodes: layout.nodes, suffix: "星球"),
                                  nodeIndices: group, center: center(of: group, nodes: layout.nodes)))
        }

        let desiredGalaxyCount = min(3, max(1, Int(ceil(sqrt(Double(planets.count) / 3)))))
        let planetNodes = planets.map {
            StarLayout.Node(point: layout.nodes[$0.nodeIndices[0]].point, position: $0.center, isEmbedded: true)
        }
        let galaxyPlanetGroups = spatialGroups(
            indices: Array(planets.indices), count: desiredGalaxyCount, nodes: planetNodes
        )
        var galaxies: [Galaxy] = []
        for (galaxyID, planetIDs) in galaxyPlanetGroups.enumerated() {
            for planetID in planetIDs {
                let old = planets[planetID]
                planets[planetID] = Planet(id: old.id, galaxyID: galaxyID, name: old.name,
                                           nodeIndices: old.nodeIndices, center: old.center)
            }
            let nodes = planetIDs.flatMap { planets[$0].nodeIndices }.sorted()
            galaxies.append(Galaxy(id: galaxyID,
                                   name: name(for: nodes, nodes: layout.nodes, suffix: "星系"),
                                   nodeIndices: nodes, planetIDs: planetIDs,
                                   center: center(of: nodes, nodes: layout.nodes)))
        }
        return Self(galaxies: galaxies, planets: planets, nodeToPlanet: nodeToPlanet)
    }

    /// Small deterministic k-means pass over the existing semantic layout.
    /// Farthest-first seeds avoid random reshuffling; empty groups are removed.
    private static func spatialGroups(indices: [Int], count requestedCount: Int,
                                      nodes: [StarLayout.Node]) -> [[Int]] {
        let count = min(max(1, requestedCount), indices.count)
        guard count > 1 else { return [indices] }
        var centers = [nodes[indices[0]].position]
        while centers.count < count {
            let next = indices.max { lhs, rhs in
                nearestDistance(nodes[lhs].position, centers) < nearestDistance(nodes[rhs].position, centers)
            }!
            centers.append(nodes[next].position)
        }
        var assignments = Array(repeating: 0, count: indices.count)
        for _ in 0..<10 {
            for (offset, index) in indices.enumerated() {
                assignments[offset] = centers.indices.min {
                    squaredDistance(nodes[index].position, centers[$0]) < squaredDistance(nodes[index].position, centers[$1])
                }!
            }
            for cluster in centers.indices {
                let members = indices.enumerated().compactMap { assignments[$0.offset] == cluster ? $0.element : nil }
                if !members.isEmpty { centers[cluster] = center(of: members, nodes: nodes) }
            }
        }
        return centers.indices.map { cluster in
            indices.enumerated().compactMap { assignments[$0.offset] == cluster ? $0.element : nil }.sorted()
        }.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
    }

    private static func nearestDistance(_ point: Point3D, _ centers: [Point3D]) -> CGFloat {
        centers.map { squaredDistance(point, $0) }.min() ?? .greatestFiniteMagnitude
    }

    private static func squaredDistance(_ lhs: Point3D, _ rhs: Point3D) -> CGFloat {
        let dx = lhs.x - rhs.x, dy = lhs.y - rhs.y, dz = lhs.z - rhs.z
        return dx * dx + dy * dy + dz * dz
    }

    private static func components(indices: [Int], links: [StarLayout.Link], threshold: CGFloat) -> [[Int]] {
        var remaining = Set(indices)
        var result: [[Int]] = []
        while let seed = remaining.min() {
            remaining.remove(seed)
            var group = [seed]
            var queue = [seed]
            while let current = queue.popLast() {
                for link in links where link.strength >= threshold {
                    let neighbor = link.a == current ? link.b : link.b == current ? link.a : nil
                    if let neighbor, remaining.remove(neighbor) != nil {
                        group.append(neighbor)
                        queue.append(neighbor)
                    }
                }
            }
            result.append(group.sorted())
        }
        return result.sorted { $0.count == $1.count ? ($0.first ?? 0) < ($1.first ?? 0) : $0.count > $1.count }
    }

    private static func center(of indices: [Int], nodes: [StarLayout.Node]) -> Point3D {
        let total = indices.reduce(Point3D(x: 0, y: 0, z: 0)) { $0 + nodes[$1].position }
        return total * (1 / CGFloat(max(1, indices.count)))
    }

    private static func name(for indices: [Int], nodes: [StarLayout.Node], suffix: String) -> String {
        let title = indices.lazy.map { nodes[$0].point.title.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "未命名"
        return String(title.prefix(8)) + suffix
    }
}
