import PointVerseKit
import SwiftUI
import CryptoKit

/// A catalog view of independent facets. Does not read or rewrite geographic communities.
struct PointFacetPrototypeView: View {
    @EnvironmentObject private var container: AppContainer
    let entries: [PointMapEntry]
    let onSelect: (PointSummary) -> Void
    @State private var dimension: PointFacetDimension = .domain
    @State private var filters: [PointFacetDimension: Set<String>] = [:]
    @State private var query = ""
    @State private var days = 0
    @State private var classifications: [PointID: PointFacetClassification] = [:]
    @State private var overrides: [PointFacetOverride] = []
    @State private var editing: PointMapEntry?
    @State private var error: String?
    @State private var loading = true
    @State private var showEmptyDomains = false
    @State private var reviews: [PointID: LCCClassificationReview] = [:]
    @State private var analysisTask: Task<Void, Never>?
    @State private var analysisProgress = ""
    @State private var useJudge = false
    @State private var confirmAll = false
    @State private var processingAll = false
    @State private var stopRequested = false
    @State private var analysisCompleted = 0
    @State private var analysisTotal = 0

    private var needsAnalysis: [PointMapEntry] {
        pendingAnalysis(in: filtered, judge: useJudge)
    }
    private var allPending: [PointMapEntry] { pendingAnalysis(in: entries, judge: true) }

    private func pendingAnalysis(in scope: [PointMapEntry], judge: Bool) -> [PointMapEntry] {
        scope.filter { entry in
            guard let record = classifications[entry.id] else { return false }
            return !record.manualDimensions.contains(.domain) && (record.values[.domain] ?? []).isEmpty
                && (reviews[entry.id]?.isCurrent(for: entry) != true
                    || (judge && reviews[entry.id]?.canRetryWithModel == true))
        }
    }

    private var reviewedEntries: [PointMapEntry] {
        filtered.filter { entry in reviews[entry.id]?.isCurrent(for: entry) == true
            && classifications[entry.id]?.manualDimensions.contains(.domain) != true }
    }

    private var signature: Int {
        var hash = Hasher()
        for item in entries { hash.combine(item.id); hash.combine(item.content); hash.combine(item.point.title) }
        return hash.finalize()
    }

    private var projectNames: [String] {
        Array(Set(overrides.filter { $0.dimension == .project }.flatMap(\.values))).sorted()
    }
    private var topicIDs: [String] {
        Array(Set(classifications.values.flatMap { Array($0.values[.topic] ?? []) })).sorted()
    }

    private var filtered: [PointMapEntry] {
        let cutoff = days == 0 ? Date.distantPast : Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? .distantPast
        return entries.filter { entry in
            guard let record = classifications[entry.id] else { return false }
            return entry.point.createdAt >= cutoff && PointFacetEngine.matches(record, filters: filters)
                && (query.isEmpty || (entry.point.title + "\n" + entry.content).localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        List {
            Section {
                Text("分类浏览原型 · \(container.storageMode == .test ? "测试数据库" : "正式数据库")").font(.headline)
                NavigationLink { PointOrganizationView() } label: { Label("全部重新整理与回收站", systemImage: "tray.2") }
                Text("主题和有效目录分类生成后直接生效，脑图与宇宙同步更新。可以随时修改，人工分类优先；仅相似度召回不自动采用。")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("按什么组织", selection: $dimension) {
                    ForEach(PointFacetDimension.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if dimension == .domain {
                    if let snapshot = LCCCatalog.snapshot {
                        Text("LCC · \(snapshot.terms.count) 个目录节点 · 离线纲要原型")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("快照：\(snapshot.snapshotID)（抓取日期，非完整分类表版本）")
                            .font(.caption2).foregroundStyle(.secondary)
                        Text("官方分类号与英文名称；中文为点界译名。关键词只提供候选，不代表官方编目结论。未收录的细类不自动补造。")
                            .font(.caption).foregroundStyle(.secondary)
                        Link("美国国会图书馆 · 官方目录来源", destination: URL(string: snapshot.indexURL)!)
                        Toggle("显示尚无内容的 LCC 目录", isOn: $showEmptyDomains)
                    } else {
                        Text("LCC 目录资源加载失败，暂不能浏览官方目录。已有人工分类仍保留。")
                            .foregroundStyle(.red)
                    }
                }
                TextField("搜索标题或内容", text: $query)
                Picker("记录时间", selection: $days) {
                    Text("全部时间").tag(0); Text("最近7天").tag(7); Text("最近30天").tag(30)
                }
            }
            Section {
                DisclosureGroup("组合筛选（\(filters.values.filter { !$0.isEmpty }.count)个维度）") {
                    ForEach(PointFacetDimension.allCases, id: \.self) { facet in
                        Menu {
                            ForEach(options(facet), id: \.self) { value in
                                Button {
                                    if filters[facet, default: []].contains(value) { filters[facet]?.remove(value) }
                                    else { filters[facet, default: []].insert(value) }
                                } label: {
                                    Label(title(value, facet: facet), systemImage: filters[facet, default: []].contains(value) ? "checkmark.square" : "square")
                                }
                            }
                            Button("清除此维度筛选") { filters[facet] = [] }
                        } label: {
                            HStack {
                                Text(facet.title)
                                Spacer()
                                Text(filters[facet, default: []].sorted().map { title($0, facet: facet) }.joined(separator: "、").isEmpty ? "不限" : filters[facet, default: []].sorted().map { title($0, facet: facet) }.joined(separator: "、"))
                                    .font(.caption).lineLimit(2)
                            }
                        }
                    }
                    Text("同一维度多选表示任一符合；不同维度需同时符合。时间指记录日期，不代表内容中谈论的年代。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("清除全部筛选") { filters = [:]; query = ""; days = 0 }
                }
            }
            if dimension == .domain {
                Section("语义归类 · 人工审阅") {
                    Toggle("一次性整理全部", isOn: Binding(get: { processingAll && !stopRequested }, set: { enabled in
                        if enabled { confirmAll = true } else { stopAnalysis() }
                    }))
                    .disabled(loading || stopRequested || (analysisTask != nil && !processingAll) || (analysisTask == nil && allPending.isEmpty))
                    Text("当前数据库有\(allPending.count)条待整理。总开关使用当前文本模型，连续处理全部待整理内容，不受搜索／时间筛选限制；关闭或离开页面会停止后续任务。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("模型提取主题，程序匹配目录后直接归类，不用逐条确认。脑图和宇宙同步按分类组织；匹配不到目录也保留主题。")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("用当前文本模型整理主题", isOn: $useJudge).disabled(analysisTask != nil)
                    if useJudge {
                        Text("若为网络模型，每条发送前600字符，不发送目录，沿用隐私授权。每条一次主题任务；调用失败可重试。不覆盖人工分类。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if analysisTask == nil {
                        Button("仅分析当前筛选（本批\(min(10, needsAnalysis.count))条）") { startAnalysis(all: false) }
                            .disabled(loading || needsAnalysis.isEmpty)
                    } else {
                        ProgressView(value: Double(analysisCompleted), total: Double(max(1, analysisTotal))) {
                            Text(analysisProgress)
                        }
                        Button(stopRequested ? "正在停止…" : "取消后续分析", role: .cancel) { stopAnalysis() }.disabled(stopRequested)
                    }
                    if analysisTask == nil && !analysisProgress.isEmpty {
                        Text(analysisProgress).font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array(reviewedEntries.prefix(20))) { entry in
                        if let review = reviews[entry.id] {
                            Button { editing = entry } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.point.title.isEmpty ? String(entry.content.prefix(50)) : entry.point.title)
                                    if let theme = review.theme { Text("主题 · " + theme).font(.headline) }
                                    if let id = review.primaryRecommendationID {
                                        Text("建议放在 · " + LCCCatalog.friendlyTitle(id)).font(.headline)
                                    }
                                    Text(review.displayStatus).font(.caption).foregroundStyle(.secondary)
                                    Text(review.decision.reason).font(.caption).lineLimit(3).foregroundStyle(.secondary)
                                    Text("查看或修改分类 →").font(.caption)
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                    if reviewedEntries.count > 20 { Text("此处显示前20条，其余可在内容的分类编辑中查看。")
                        .font(.caption).foregroundStyle(.secondary) }
                }
            }
            if loading { ProgressView("读取分类…") }
            if let error { Text(error).foregroundStyle(.red) }
            Section("\(filtered.count) 条独立 Point · 多归属时分组数量可能相加超过总数") {
                if dimension == .project {
                    Text("项目只使用人工指定的信息，不会因为出现某个名字就自动认定归属。可点记录右侧的分类按钮指定项目。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(options(dimension).filter { value in !members(value).isEmpty || (dimension == .domain && showEmptyDomains && LCCCatalog.byID[value] != nil) }, id: \.self) { value in
                    NavigationLink {
                        FacetCatalogGroupView(termID: value, dimension: dimension, entries: members(value),
                                              classifications: classifications, onSelect: onSelect, onEdit: { editing = $0 })
                    } label: {
                        HStack {
                            Text(title(value, facet: dimension))
                            Spacer()
                            Text("\(members(value).count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                if !loading && filtered.isEmpty { Text("没有符合条件的记录，可清除筛选后重试。") }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground))
        .task(id: signature) { await reload() }
        .onDisappear { analysisTask?.cancel() }
        .confirmationDialog("一次性整理全部\(allPending.count)条内容？", isPresented: $confirmAll, titleVisibility: .visible) {
            Button("开始整理") { useJudge = true; startAnalysis(all: true) }
            Button("取消", role: .cancel) { }
        } message: {
            Text("范围是当前\(container.storageMode == .test ? "测试" : "正式")数据库的全部待整理内容，不限于筛选结果。若当前模型是网络模型，会逐条发送前600字符，可能产生费用，沿用已有授权。分类直接生效、可修改，不覆盖人工分类。每条本轮只尝试一次。")
        }
        .sheet(item: $editing, onDismiss: { Task { await reload() } }) { entry in
            FacetOverrideEditor(entry: entry, initialDimension: dimension,
                                classification: classifications[entry.id], overrides: overrides, projectNames: projectNames, topicIDs: topicIDs)
                .environmentObject(container)
        }
    }

    private func options(_ facet: PointFacetDimension) -> [String] {
        let values = facet == .project ? projectNames : PointFacetEngine.terms.filter { term in
            term.dimension == facet && (facet != .domain || term.parentID == nil)
                && (!PointFacetEngine.isLegacyDomain(term.id) || classifications.values.contains { record in
                    (record.values[.domain] ?? []).contains { PointFacetEngine.belongs($0, to: term.id) }
                })
        }.map(\.id)
        return (facet == .topic ? Array(Set(values + topicIDs)).sorted() : values) + [PointFacetEngine.unassigned]
    }

    private func title(_ value: String, facet: PointFacetDimension) -> String {
        value == PointFacetEngine.unassigned ? (facet == .project ? "未指定项目" : (facet == .domain ? "尚未匹配知识领域" : "暂无分类候选")) : (facet == .project ? value : (facet == .domain ? LCCCatalog.friendlyTitle(value) : PointFacetEngine.title(value)))
    }

    private func members(_ value: String) -> [PointMapEntry] {
        filtered.filter { item in
            let values = classifications[item.id]?.values[dimension] ?? []
            return value == PointFacetEngine.unassigned ? values.isEmpty : values.contains {
                dimension == .domain ? PointFacetEngine.belongs($0, to: value) : $0 == value
            }
        }
    }

    @MainActor private func reload() async {
        do {
            let saved = try await container.database.facetOverrides()
            let savedReviews = try await container.database.lccClassificationReviews()
            let values = entries
            let classified = await Task.detached(priority: .userInitiated) {
                let byID = Dictionary(grouping: saved, by: \.pointID)
                let reviewByID = Dictionary(uniqueKeysWithValues: savedReviews.map { ($0.pointID, $0) })
                return Dictionary(uniqueKeysWithValues: values.map { entry in
                    (entry.id, PointFacetEngine.classify(entry, overrides: byID[entry.id] ?? [], review: reviewByID[entry.id]))
                })
            }.value
            guard !Task.isCancelled else { return }
            overrides = saved; classifications = classified; error = nil
            reviews = Dictionary(uniqueKeysWithValues: savedReviews.map { ($0.pointID, $0) })
        } catch { self.error = "读取分类失败：\(error.localizedDescription)" }
        loading = false
    }

    private func startAnalysis(all: Bool) {
        guard analysisTask == nil else { return }
        // New work first; explicit retries must not starve untouched records.
        let sorted = (all ? allPending : needsAnalysis).sorted { lhs, rhs in
            let left = reviews[lhs.id]?.isCurrent(for: lhs) == true
            let right = reviews[rhs.id]?.isCurrent(for: rhs) == true
            return !left && right
        }
        let batch = all ? sorted : Array(sorted.prefix(10))
        guard !batch.isEmpty else { return }
        let judge = all || useJudge
        processingAll = all
        stopRequested = false
        analysisCompleted = 0; analysisTotal = batch.count
        analysisTask = Task { @MainActor in
            defer { analysisTask = nil; processingAll = false; stopRequested = false }
            var completed = 0
            var failed = 0
            do {
                for entry in batch {
                    try Task.checkCancellation()
                    let position = completed + 1
                    let review = try await container.analyzeLCC(entry, useJudge: judge) { message in
                        analysisProgress = "\(position)/\(batch.count) · \(message)"
                    }
                    reviews[entry.id] = review
                    classifications[entry.id] = PointFacetEngine.classify(entry,
                        overrides: overrides.filter { $0.pointID == entry.id }, review: review)
                    completed += 1
                    analysisCompleted = completed
                    if review.decision.status == .failed { failed += 1 }
                }
                analysisProgress = "已处理\(completed)条，失败\(failed)条；有效主题与目录已生效，脑图／宇宙同步更新。"
            } catch is CancellationError {
                analysisProgress = "已取消后续分析，保留已完成的\(completed)条候选。"
            } catch {
                analysisProgress = "已完成\(completed)条；\(error.localizedDescription)"
            }
        }
    }

    private func stopAnalysis() {
        stopRequested = true
        analysisProgress = "正在停止后续任务；当前推理可能需要结束后才能释放模型。"
        analysisTask?.cancel()
    }
}

private struct FacetCatalogGroupView: View {
    let termID: String
    let dimension: PointFacetDimension
    let entries: [PointMapEntry]
    let classifications: [PointID: PointFacetClassification]
    let onSelect: (PointSummary) -> Void
    let onEdit: (PointMapEntry) -> Void
    @State private var limit = 50

    private var children: [PointFacetTerm] {
        PointFacetEngine.terms.filter { $0.dimension == dimension && $0.parentID == termID }
    }

    private func members(_ term: String) -> [PointMapEntry] {
        entries.filter { entry in (classifications[entry.id]?.values[dimension] ?? []).contains { PointFacetEngine.belongs($0, to: term) } }
    }

    private var groupedTopics: [String] {
        var topics = Set<String>()
        for entry in entries {
            topics.formUnion(classifications[entry.id]?.values[.topic] ?? Set<String>())
        }
        return topics.sorted()
    }

    private func topicMembers(_ topic: String) -> [PointMapEntry] {
        entries.filter { classifications[$0.id]?.values[.topic]?.contains(topic) == true }
    }

    var body: some View {
        List {
            Section {
                Text("\(entries.count) 条独立 Point；本页只改变查看角度，不改变原文和地图位置。")
                    .font(.caption).foregroundStyle(.secondary)
                if let term = LCCCatalog.byID[termID] {
                    DisclosureGroup("标准分类详情") {
                    Text(term.displayTitle)
                    Text(term.englishTitle).font(.headline)
                    if term.chineseTitle != nil { Text("中文为点界译名，非官方中文分类名。通常只收录大类与分支纲要；计算机软件补充选定范围，不是完整细目表。")
                        .font(.caption).foregroundStyle(.secondary) }
                    if let url = URL(string: term.sourceURL) {
                        Link("官方 PDF · 第\(term.sourcePage)页", destination: url)
                    }
                    }
                }
            }
            if !children.isEmpty {
                Section("继续细分") {
                    ForEach(children.filter { LCCCatalog.byID[$0.id] != nil || !members($0.id).isEmpty }) { child in
                        NavigationLink("\(dimension == .domain ? LCCCatalog.friendlyTitle(child.id) : child.title)（\(members(child.id).count)）") {
                            FacetCatalogGroupView(termID: child.id, dimension: dimension, entries: members(child.id),
                                                  classifications: classifications, onSelect: onSelect, onEdit: onEdit)
                        }
                    }
                }
            }
            if dimension == .domain, termID != PointFacetEngine.unassigned {
                Section("下面的主题") {
                    ForEach(groupedTopics, id: \.self) { topic in
                        let subset = topicMembers(topic)
                        NavigationLink("\(PointFacetEngine.title(topic))（\(subset.count)）") {
                            FacetCatalogGroupView(termID: topic, dimension: .topic, entries: subset,
                                classifications: classifications, onSelect: onSelect, onEdit: onEdit)
                        }
                    }
                }
            }
            Section("本范围全部内容") {
                ForEach(Array(entries.prefix(limit))) { entry in
                    HStack(alignment: .top) {
                        Button { onSelect(entry.point) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(entry.point.title.isEmpty ? "未命名 Point" : entry.point.title).font(.headline)
                                Text(entry.content).font(.caption).lineLimit(3).foregroundStyle(.secondary)
                                Text((classifications[entry.id]?.manualDimensions.contains(dimension) == true) ? "本维度：人工指定" : (classifications[entry.id]?.modelDimensions.contains(dimension) == true ? "本维度：含模型主题，可修改" : (dimension == .project ? "本维度：尚未指定" : "本维度：规则候选 · 待确认")))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                        Button { onEdit(entry) } label: { Image(systemName: "slider.horizontal.3") }
                            .buttonStyle(.borderless).accessibilityLabel("修改\(entry.point.title)的分类")
                    }
                }
                if entries.count > limit { Button("再显示50条") { limit += 50 } }
            }
        }
        .navigationTitle(termID == PointFacetEngine.unassigned ? "尚未归类" : (dimension == .project ? termID : (dimension == .domain ? LCCCatalog.friendlyTitle(termID) : PointFacetEngine.title(termID))))
    }
}

private struct FacetOverrideEditor: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss
    let entry: PointMapEntry
    let initialDimension: PointFacetDimension
    let classification: PointFacetClassification?
    let overrides: [PointFacetOverride]
    let projectNames: [String]
    let topicIDs: [String]
    @State private var dimension: PointFacetDimension = .domain
    @State private var values: Set<String> = []
    @State private var manual = false
    @State private var newProject = ""
    @State private var catalogQuery = ""
    @State private var saving = false
    @State private var error: String?
    @State private var semanticReview: LCCClassificationReview?
    @State private var semanticTask: Task<Void, Never>?
    @State private var semanticProgress = ""
    @State private var useJudge = false
    @State private var showAlternatives = false
    @State private var showFullCatalog = false

    var body: some View {
        NavigationStack {
            Form {
                Text(entry.point.title).font(.headline)
                Picker("修改哪个维度", selection: $dimension) {
                    ForEach(PointFacetDimension.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if dimension != .domain {
                    Toggle("由我指定这个维度", isOn: $manual)
                    Text("空选择表示暂不归类；关闭并保存可恢复自动候选。只保存当前维度。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if dimension == .project {
                    HStack {
                        TextField("项目名称（最多80字符）", text: $newProject)
                        Button("加入") {
                            let value = newProject.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !value.isEmpty && value.count <= 80 { values.insert(value); manual = true; newProject = "" }
                        }.disabled(newProject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newProject.count > 80)
                    }
                }
                if dimension == .domain {
                    domainReview
                }
                ForEach(dimension == .domain ? [] : options, id: \.self) { value in
                    Toggle(dimension == .project ? value : PointFacetEngine.title(value), isOn: Binding(
                        get: { values.contains(value) },
                        set: { enabled in
                            manual = true
                            if enabled { values.insert(value) } else { values.remove(value) }
                        }))
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("独立分类标注")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    if dimension != .domain {
                    Button(saving ? "保存中…" : "保存") {
                        Task {
                            saving = true
                            defer { saving = false }
                            do {
                                try await container.database.saveFacetOverride(pointID: entry.id, dimension: dimension,
                                                                              values: manual ? Array(values) : nil)
                                dismiss()
                            } catch { self.error = error.localizedDescription }
                        }
                    }.disabled(saving || semanticTask != nil)
                    }
                }
            }
            .onAppear { dimension = initialDimension; loadSelection() }
            .task {
                do {
                    semanticReview = try await container.database.lccClassificationReviews()
                        .first { $0.isCurrent(for: entry) }
                } catch { self.error = "读取语义候选失败：\(error.localizedDescription)" }
            }
            .onDisappear { semanticTask?.cancel() }
            .onChange(of: dimension) { _, _ in loadSelection() }
            .interactiveDismissDisabled(saving)
        }
    }

    private var options: [String] {
        dimension == .project ? Array(Set(projectNames).union(values)).sorted()
            : Array(Set(PointFacetEngine.terms.filter { $0.dimension == dimension }.map(\.id)
                + (dimension == .topic ? topicIDs + Array(values) + (semanticReview?.theme.map { [PointThemeClassifier.topicID($0)] } ?? []) : []))).sorted()
    }

    private var primaryDomain: String? {
        if manual { return values.sorted().first }
        if let review = semanticReview {
            return review.primaryRecommendationID
        }
        return values.sorted().first
    }

    private var alternativeDomains: [String] {
        let candidates = (semanticReview?.decision.ids ?? []) + (semanticReview?.candidates.map(\.id) ?? [])
        var seen = Set<String>()
        return candidates.filter { $0 != primaryDomain && seen.insert($0).inserted }
    }

    @ViewBuilder private var domainReview: some View {
        Section {
            if let theme = semanticReview?.theme {
                Text("内容主题").font(.caption).foregroundStyle(.secondary)
                Text(theme).font(.title2.bold())
            }
            Text(manual ? "当前分类" : (automaticallyApplied ? "已自动归类" : "建议放在")).font(.caption).foregroundStyle(.secondary)
            if let primary = primaryDomain {
                Text(LCCCatalog.friendlyTitle(primary)).font(.title2.bold())
                if manual && values.count > 1 {
                    Text("另有：" + values.sorted().dropFirst().map { LCCCatalog.friendlyTitle($0) }.joined(separator: "、"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(manual ? "暂不分类" : (semanticReview?.theme == nil ? "还不能确定放在哪里" : "主题已保留，可重新分析以推荐参考分类")).font(.headline)
            }
            if !manual, let review = semanticReview {
                Text(review.decision.reason).font(.callout).lineLimit(3)
                if review.decision.status == .retrievalOnly {
                    Text("只是语义上接近，还没有模型判断。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if !manual && primaryDomain != nil {
                Text("根据内容中的关键词提出，等你确认。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button(saving ? "保存中…" : (primaryDomain == nil ? (semanticReview?.theme != nil && !manual ? "推荐参考分类" : "选择分类") : (manual ? "保存修改" : "确认分类"))) {
                    if primaryDomain == nil, semanticReview?.theme != nil, !manual {
                        useJudge = true
                        analyzeSemantic()
                    } else if primaryDomain == nil {
                        showAlternatives = true
                        showFullCatalog = true
                    } else {
                        let selected = manual ? values : Set(primaryDomain.map { [$0] } ?? [])
                        saveDomain(Array(selected))
                    }
                }.buttonStyle(.borderedProminent).disabled(saving || semanticTask != nil)
                Button("换一个") { showAlternatives.toggle() }.disabled(saving || semanticTask != nil)
                Button("暂不分类") { saveDomain([]) }.disabled(saving || semanticTask != nil)
            }
            Text("确认会保存为你的分类选择；没有匹配目录时，请换一个分类或选择暂不分类。已有人工分类优先。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        if showAlternatives {
            Section("换个更合适的") {
                ForEach(Array(alternativeDomains.prefix(3)), id: \.self) { id in
                    Button(LCCCatalog.friendlyTitle(id)) { values = [id]; manual = true; showAlternatives = false }
                }
                if let second = semanticReview?.decision.ids.dropFirst().first, !values.contains(second) {
                    Button("也涉及\(LCCCatalog.friendlyTitle(second))？加入第二分类") {
                        values = Set(primaryDomain.map { [$0, second] } ?? [second]); manual = true
                    }
                }
                DisclosureGroup("自己查找其他分类", isExpanded: $showFullCatalog) {
                    TextField("搜索日常名称、分类号或中英文", text: $catalogQuery)
                    ForEach(Array(options.filter { id in
                        catalogQuery.isEmpty ? LCCCatalog.byID[id]?.parentID == nil
                            : (LCCCatalog.friendlyTitle(id) + " " + PointFacetEngine.title(id)
                            + " " + (LCCCatalog.byID[id]?.englishTitle ?? "")).localizedCaseInsensitiveContains(catalogQuery)
                    }.prefix(catalogQuery.isEmpty ? 30 : 20)), id: \.self) { id in
                        Button(LCCCatalog.friendlyTitle(id)) { values = [id]; manual = true; showAlternatives = false }
                    }
                    Text(catalogQuery.isEmpty ? "可直接选择大类，也可输入关键词查找细分目录。" : "最多显示20条，可补充关键词缩小范围。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("选择后点击“保存修改”才会生效；取消不会改动已保存分类。")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(saving || semanticTask != nil)
        }
        Section {
            DisclosureGroup("重新分析与模型设置") {
                Toggle("用当前文本模型整理主题", isOn: $useJudge).disabled(semanticTask != nil)
                Text("模型提取主题；精确匹配不到时推荐接近的参考分类，不需要 E5。网络模型发送内容前600字符及参考大类名称，沿用隐私授权。关闭后只做本地语义检索。")
                    .font(.caption).foregroundStyle(.secondary)
                if semanticTask == nil {
                    Button(semanticReview == nil ? "帮我找个分类" : "重新分析") { analyzeSemantic() }
                } else {
                    ProgressView(semanticProgress)
                    Button("取消分析") { semanticTask?.cancel() }
                }
            }
            DisclosureGroup("分类依据与标准详情") {
                Text("名称是点界的日常显示名，底层LCC编号和官方名称不变。")
                    .font(.caption).foregroundStyle(.secondary)
                if let id = primaryDomain, let term = LCCCatalog.byID[id] {
                    Text(term.displayTitle)
                    Text(term.englishTitle).font(.caption)
                    if let url = URL(string: term.sourceURL) { Link("官方目录来源", destination: url) }
                }
                if let review = semanticReview {
                    Text(review.displayStatus)
                    Text(review.decision.reason).font(.caption)
                    if let raw = review.rawTheme { Text("模型原主题：\(raw)\n归一后主题：\(review.theme ?? raw)\n程序映射版本：\(review.mappingVersion ?? "无")").font(.caption) }
                    if let issue = review.refinementIssue { Text(issue).font(.caption).foregroundStyle(.secondary) }
                    Text("召回模型：\(review.embeddingModelID)\n判断模型：\(review.judgeModelID ?? "未使用／调用未成功")\n\(review.snapshotID) · \(review.createdAt.formatted())")
                        .font(.caption2).foregroundStyle(.secondary)
                    ForEach(review.candidates) { candidate in
                        Text("\(PointFacetEngine.title(candidate.id)) · 召回余弦 \(candidate.cosine, specifier: "%.3f")（非正确率）")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Button("移除我的分类，恢复自动候选") { saveDomain(nil) }.disabled(saving || semanticTask != nil)
            }
        }
    }

    private func saveDomain(_ ids: [String]?) {
        saving = true
        Task { @MainActor in
            defer { saving = false }
            do {
                try await container.database.saveFacetOverride(pointID: entry.id, dimension: .domain, values: ids)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }

    private var automaticallyApplied: Bool {
        guard let review = semanticReview, review.isCurrent(for: entry), review.theme != nil else { return false }
        guard review.decision.status == .suggested, let id = review.primaryRecommendationID else { return false }
        return PointFacetEngine.classify(entry, overrides: overrides, review: review).values[.domain]?.contains(id) == true
    }

    private func analyzeSemantic() {
        let judge = useJudge
        error = nil
        semanticTask = Task { @MainActor in
            defer { semanticTask = nil }
            do {
                semanticReview = try await container.analyzeLCC(entry, useJudge: judge) { semanticProgress = $0 }
            } catch is CancellationError {
                semanticProgress = "已取消"
            } catch { self.error = error.localizedDescription }
        }
    }

    private func loadSelection() {
        manual = overrides.contains { $0.pointID == entry.id && $0.dimension == dimension }
        values = semanticReview == nil ? (classification?.values[dimension] ?? [])
            : (PointFacetEngine.classify(entry, overrides: overrides, review: semanticReview).values[dimension] ?? [])
        newProject = ""; catalogQuery = ""; error = nil; showAlternatives = false; showFullCatalog = false
    }
}

struct ReadOnlyHierarchyMindMap: View {
    let layout: StarLayout
    let entries: [PointMapEntry]
    let embeddings: [PointEmbeddingRecord]
    let geographies: [PointGeographyRecord]
    let focusRequest: PointMapFocusRequest?
    let onSelect: (PointSummary) -> Void
    @State private var root = MindMapBranch(id: "mindmap-root")
    @State private var branches: [String: MindMapBranch] = [:]
    @State private var labels: [String: MindMapLabel] = [:]
    @State private var placements: [MindMapPlacement] = []
    @State private var expanded: Set<String> = ["mindmap-root"]
    @State private var limits: [String: Int] = [:]
    @State private var selectedID: String?
    @State private var focusedID: String?
    @State private var zoom: CGFloat = 1
    @State private var pan = CGSize.zero
    @State private var dragStart: CGSize?
    @State private var pinchStart: CGFloat?
    @State private var loading = true
    @State private var viewportSize = CGSize.zero

    private var inputSignature: Int {
        var hash = Hasher()
        for entry in entries { hash.combine(entry.id); hash.combine(entry.point.title); hash.combine(entry.content) }
        for item in embeddings { hash.combine(item.pointID); hash.combine(item.revision) }
        for item in geographies.sorted(by: { $0.pointID.rawValue.uuidString < $1.pointID.rawValue.uuidString }) {
            hash.combine(item.pointID); hash.combine(item.communityID); hash.combine(item.latitude); hash.combine(item.longitude)
        }
        return hash.finalize()
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("只读 · 按当前分类组织，与宇宙同步；不代表因果关系。点箭头逐级展开。")
                .font(.caption2).foregroundStyle(.white.opacity(0.8))
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        GeometryReader { proxy in
            ZStack {
                Color.clear.contentShape(Rectangle())
                Canvas { context, size in
                    let byID = Dictionary(uniqueKeysWithValues: placements.map { ($0.id, $0) })
                    for item in placements {
                        guard let parentID = item.parentID, let parent = byID[parentID] else { continue }
                        let from = screen(parent, size: size), to = screen(item, size: size)
                        var path = Path()
                        let start = CGPoint(x: from.x + 106 * zoom, y: from.y)
                        let end = CGPoint(x: to.x - 106 * zoom, y: to.y)
                        path.move(to: start)
                        let midX = (start.x + end.x) / 2
                        path.addCurve(to: end, control1: CGPoint(x: midX, y: start.y), control2: CGPoint(x: midX, y: end.y))
                        context.stroke(path, with: .color(.cyan.opacity(0.35)), lineWidth: max(1, zoom))
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture().onChanged { value in
                    if dragStart == nil { dragStart = pan }
                    pan = CGSize(width: (dragStart?.width ?? 0) + value.translation.width,
                                 height: (dragStart?.height ?? 0) + value.translation.height)
                }.onEnded { _ in dragStart = nil })

                ForEach(placements.filter { isVisible($0, size: proxy.size) }, id: \.id) { item in
                    nodeCard(item, size: proxy.size)
                        .scaleEffect(zoom)
                        .position(screen(item, size: proxy.size))
                }
                if loading { ProgressView("准备层级脑图…").tint(.white).foregroundStyle(.white) }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .simultaneousGesture(MagnifyGesture().onChanged { value in
                if pinchStart == nil { pinchStart = zoom }
                setZoom((pinchStart ?? zoom) * value.magnification)
            }.onEnded { _ in pinchStart = nil })
            .task(id: inputSignature) { viewportSize = proxy.size; await prepare(size: proxy.size) }
            .onChange(of: focusRequest) { _, request in
                if let request { focus(pointID: request.pointID, size: proxy.size) }
            }
            .onChange(of: proxy.size) { oldSize, size in
                viewportSize = size
                // A detail bubble opening/closing is not a camera command.
                // Preserve scale and absolute card positions as the viewport changes.
                if oldSize.width > 0, oldSize.height > 0 {
                    pan.width += (oldSize.width - size.width) / 2
                    pan.height += (oldSize.height - size.height) / 2
                }
            }
        }
        bottomPanel
        }
    }

    private var bottomPanel: some View {
                VStack(spacing: 8) {
                    if let selectedID, let label = labels[selectedID] {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(label.title).font(.headline).lineLimit(2)
                                Spacer()
                                Button("定位") { focusNode(selectedID, size: viewportSize) }
                                Button { self.selectedID = nil } label: { Image(systemName: "xmark.circle") }
                            }
                            Text(breadcrumb(selectedID)).font(.caption2).lineLimit(2).foregroundStyle(.secondary)
                            if let point = label.point {
                                Text(label.preview).font(.caption).lineLimit(3)
                                Button("打开原文") { onSelect(point) }
                            } else {
                                Text("\(label.level) · \(label.count) 条 Point · 只读浏览，不改变分类").font(.caption)
                                if expanded.contains(selectedID), let children = branches[selectedID]?.children, !children.isEmpty {
                                    ScrollView(.vertical) {
                                        VStack(alignment: .leading, spacing: 8) {
                                            ForEach(Array(children.prefix(limits[selectedID] ?? 24)), id: \.id) { child in
                                                Button(labels[child.id]?.title ?? "未命名") {
                                                    focusNode(child.id, size: viewportSize)
                                                }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                                            }
                                        }
                                    }.frame(height: min(88, CGFloat(children.count) * 30))
                                }
                            }
                        }.padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                    HStack(spacing: 18) {
                        Button { setZoom(zoom / 1.3) } label: { Image(systemName: "minus.magnifyingglass") }
                            .accessibilityLabel("缩小脑图")
                        Button { fit(size: viewportSize) } label: { Label("适合屏幕", systemImage: "arrow.up.left.and.arrow.down.right") }
                        Button("收起全部") {
                            expanded = [root.id]; limits = [:]; selectedID = nil; focusedID = nil; refreshLayout(); fit(size: viewportSize)
                        }
                        Button { setZoom(zoom * 1.3) } label: { Image(systemName: "plus.magnifyingglass") }
                            .accessibilityLabel("放大脑图")
                    }
                    .font(.caption).padding(12).background(.regularMaterial, in: Capsule())
                }.padding(10)
    }

    private func screen(_ item: MindMapPlacement, size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2 + CGFloat(item.x) * zoom + pan.width,
                y: size.height / 2 + CGFloat(item.y) * zoom + pan.height)
    }

    private func isVisible(_ item: MindMapPlacement, size: CGSize) -> Bool {
        let point = screen(item, size: size)
        return point.x > -120 * zoom && point.x < size.width + 120 * zoom
            && point.y > -44 * zoom && point.y < size.height + 44 * zoom
    }

    @ViewBuilder private func nodeCard(_ item: MindMapPlacement, size: CGSize) -> some View {
        if let parent = item.moreForParentID {
            Button("再显示24项…") {
                limits[parent] = (limits[parent] ?? 24) + 24
                refreshLayout(anchor: parent)
                selectedID = nil
                centerBranch(parent, size: size)
            }
            .font(.caption).frame(width: 212, height: 68)
            .background(.indigo.opacity(0.85), in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(.white)
        } else if let label = labels[item.id] {
            HStack(spacing: 8) {
                Button {
                    focusNode(item.id, size: size)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(label.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                        Text(label.point == nil ? "\(label.level) · \(label.count)条" : "Point · 查看原文")
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
                if !(branches[item.id]?.children.isEmpty ?? true) {
                    Button {
                        if expanded.contains(item.id) { expanded.remove(item.id) } else { expanded.insert(item.id) }
                        refreshLayout(anchor: item.id)
                        selectedID = nil
                        centerBranch(item.id, size: size)
                    } label: {
                        Image(systemName: expanded.contains(item.id) ? "chevron.down.circle.fill" : "chevron.right.circle.fill")
                            .font(.title3).frame(width: 34, height: 44)
                    }.buttonStyle(.plain).accessibilityLabel("\(expanded.contains(item.id) ? "收起" : "展开")\(label.title)")
                }
            }
            .padding(.horizontal, 10).frame(width: 212, height: 68)
            .foregroundStyle(.white)
            .background(label.point == nil ? Color.indigo.opacity(0.85) : Color(red: 0.08, green: 0.25, blue: 0.3), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(focusedID == item.id ? .yellow : .white.opacity(0.25), lineWidth: focusedID == item.id ? 2 : 1))
        }
    }

    private func refreshLayout(anchor: String? = nil) {
        let old = placements.first { $0.id == anchor }
        placements = ReadOnlyMindMapLayout.make(root: root, expanded: expanded, limits: limits)
        if let old, let new = placements.first(where: { $0.id == anchor }) {
            pan.width += CGFloat(old.x - new.x) * zoom
            pan.height += CGFloat(old.y - new.y) * zoom
        }
    }

    private func setZoom(_ value: CGFloat) {
        let next = min(4, max(0.001, value)), factor = next / zoom
        pan = CGSize(width: pan.width * factor, height: pan.height * factor)
        zoom = next
    }

    private func fit(size: CGSize) {
        guard let minX = placements.map(\.x).min(), let maxX = placements.map(\.x).max(),
              let minY = placements.map(\.y).min(), let maxY = placements.map(\.y).max() else { return }
        zoom = min(1, max(0.001, min((size.width - 32) / CGFloat(maxX - minX + 232),
                                  max(80, size.height - 120) / CGFloat(maxY - minY + 108))))
        pan = CGSize(width: -CGFloat(minX + maxX) / 2 * zoom, height: -CGFloat(minY + maxY) / 2 * zoom)
    }

    private func breadcrumb(_ id: String) -> String {
        var titles: [String] = [], current: String? = id
        while let value = current, let label = labels[value] { titles.append(label.title); current = label.parent }
        return titles.reversed().joined(separator: " › ")
    }

    private func focus(pointID: PointID, size: CGSize) {
        let id = "mindmap-point:" + pointID.rawValue.uuidString
        focusNode(id, size: size, showsDetails: false)
    }

    private func focusNode(_ id: String, size: CGSize, showsDetails: Bool = true) {
        guard labels[id] != nil else { return }
        var current: String? = id
        while let value = current, let parent = labels[value]?.parent {
            expanded.insert(parent)
            if let index = branches[parent]?.children.firstIndex(where: { $0.id == value }) {
                limits[parent] = max(limits[parent] ?? 24, index + 1)
            }
            current = parent
        }
        refreshLayout(); selectedID = showsDetails ? id : nil
        centerBranch(id, size: size)
    }

    private func centerBranch(_ id: String, size: CGSize) {
        guard let camera = ReadOnlyMindMapLayout.focus(id: id, placements: placements,
                                                      width: size.width, height: size.height) else { return }
        dragStart = nil; pinchStart = nil
        focusedID = id
        zoom = camera.zoom
        pan = CGSize(width: camera.offsetX, height: camera.offsetY)
    }

    @MainActor private func prepare(size: CGSize) async {
        let needsInitialFit = labels.isEmpty
        let overrides = UserDefaults.standard.data(forKey: "semanticGeography.placeNameOverrides.v1")
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        let scopes = await Task.detached(priority: .userInitiated) {
            EvaluationHierarchy.make(layout: layout, entries: entries, embeddings: embeddings, geographies: geographies, overrides: overrides)
        }.value
        guard !Task.isCancelled else { return }
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        var newLabels: [String: MindMapLabel] = [:], newBranches: [String: MindMapBranch] = [:]
        func convert(_ scope: EvaluationProvince, parent: String) -> MindMapBranch {
            newLabels[scope.id] = .init(title: scope.name, level: scope.level, count: scope.members.count, parent: parent, point: nil, preview: "")
            let children: [MindMapBranch]
            if !scope.children.isEmpty { children = scope.children.map { convert($0, parent: scope.id) } }
            else {
                children = scope.members.compactMap { member in
                    guard let entry = byID[member.id] else { return nil }
                    let id = "mindmap-point:" + member.id.rawValue.uuidString
                    newLabels[id] = .init(title: entry.point.title.isEmpty ? String(entry.content.prefix(40)) : entry.point.title,
                        level: "Point", count: 1, parent: scope.id, point: entry.point, preview: String(entry.content.prefix(240)))
                    let branch = MindMapBranch(id: id); newBranches[id] = branch; return branch
                }
            }
            let branch = MindMapBranch(id: scope.id, children: children); newBranches[scope.id] = branch; return branch
        }
        let rootID = "mindmap-root"
        newLabels[rootID] = .init(title: "我的宇宙", level: "地图层级", count: entries.count, parent: nil, point: nil, preview: "")
        root = MindMapBranch(id: rootID, children: scopes.map { convert($0, parent: rootID) })
        newBranches[rootID] = root; labels = newLabels; branches = newBranches
        expanded = expanded.intersection(Set(newLabels.keys)).union([rootID])
        if let selectedID, labels[selectedID] == nil { self.selectedID = nil }
        if let focusedID, labels[focusedID] == nil { self.focusedID = nil }
        refreshLayout(anchor: needsInitialFit ? nil : (focusedID ?? rootID)); loading = false
        if needsInitialFit {
            if let focusRequest { focus(pointID: focusRequest.pointID, size: size) } else { fit(size: size) }
        }
    }
}

private struct MindMapLabel {
    let title: String
    let level: String
    let count: Int
    let parent: String?
    let point: PointSummary?
    let preview: String
}

/// Uses the active container's database, never shared UserDefaults for review evidence.
struct ProvinceEvaluationIndexView: View {
    var existingLayout: StarLayout? = nil
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss
    @State private var groups: [EvaluationProvince] = []
    @State private var embeddings: [PointEmbeddingRecord] = []
    @State private var error: String?
    @State private var loading = true
    @State private var reviewed: Set<String> = []

    var body: some View {
        Group {
            if loading { ProgressView("读取省份…") }
            else if let error { Text(error).foregroundStyle(.red) }
            else {
                EvaluationScopeBrowser(nodes: groups, embeddings: embeddings, reviewed: reviewed)
            }
        }
        .navigationTitle("分层质量评估")
        .toolbar { Button("完成") { dismiss() } }
        .task {
            do {
                let entries = try await container.database.pointMapEntries()
                let originalGeography = try await container.database.geographies(version: GeographyIdentity.relativeSemanticV6)
                let manualClassifications = try await container.database.facetOverrides()
                let classificationReviews = try await container.database.lccClassificationReviews()
                let geography = ClassificationMapProjection.make(entries: entries, geographies: originalGeography,
                    overrides: manualClassifications, reviews: classificationReviews)
                let loaded = try await container.database.embeddings(modelID: EmbeddingModelIdentity.multilingualE5Small)
                let overrides = UserDefaults.standard.data(forKey: "semanticGeography.placeNameOverrides.v1")
                    .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
                let ids = Set(entries.map(\.id))
                let layout: StarLayout
                if let existingLayout, Set(existingLayout.nodes.map { $0.point.id }) == ids {
                    layout = existingLayout
                } else {
                    layout = StarLayoutEngine.make(entries: entries, embeddings: loaded)
                }
                groups = await Task.detached(priority: .userInitiated) {
                    EvaluationHierarchy.make(layout: layout, entries: entries, embeddings: loaded, geographies: geography, overrides: overrides)
                }.value
                reviewed = try await container.database.evaluatedScopeIDs()
                embeddings = loaded
            } catch { self.error = error.localizedDescription }
            loading = false
        }
    }
}

struct EvaluationProvince: Identifiable, Sendable {
    let id: String
    var name: String
    let members: [ProvinceEvaluation.Member]
    var level = "省"
    var path: [String] = []
    var children: [EvaluationProvince] = []
    var mapLabelID: String? = nil
    var generatedName: String? = nil
}

enum EvaluationHierarchy {
    static func make(layout: StarLayout, entries: [PointMapEntry], embeddings: [PointEmbeddingRecord],
                     geographies: [PointGeographyRecord], overrides: [String: String]) -> [EvaluationProvince] {
        let geography = Dictionary(uniqueKeysWithValues: geographies.map { ($0.pointID, $0) })
        let hierarchy = CosmicHierarchy.make(layout: layout, geographies: geography)
        let entriesByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        let revisions = Dictionary(uniqueKeysWithValues: embeddings.map { ($0.pointID, $0.revision) })
        func members(_ indices: [Int]) -> [ProvinceEvaluation.Member] {
            indices.map { index in
                let point = layout.nodes[index].point
                return .init(id: point.id, revision: revisions[point.id], text: point.title + "\n" + (entriesByID[point.id]?.content ?? ""))
            }.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
        }
        func identity(_ indices: [Int], level: String) -> String {
            let input = indices.map { layout.nodes[$0].point.id.rawValue.uuidString }.sorted().joined(separator: ":")
            let digest = SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
            return "evaluation:\(level):\(digest)"
        }
        func name(_ indices: [Int], level: AdministrativeLevel, key: String, suffix: String) -> String {
            overrides[key].flatMap { $0.isEmpty ? nil : $0 } ?? SemanticPlaceNameEngine.name(
                contents: indices.map { entriesByID[layout.nodes[$0].point.id]?.content ?? layout.nodes[$0].point.title }, level: level) + suffix
        }
        let built = hierarchy.galaxies.map { system in
            let systemPath = [system.name]
            let planets = system.planetIDs.map { planetID in
                let planet = hierarchy.planets[planetID]
                let planetPath = systemPath + [planet.name]
                let planetKey = identity(planet.nodeIndices, level: "planet")
                let grouped = Dictionary(grouping: planet.nodeIndices) { index in
                    let community = geography[layout.nodes[index].point.id]?.communityID
                    return ClassificationMapProjection.region(community)?.provinceCommunityID ?? community ?? "__unassigned"
                }
                let provinces = grouped.keys.sorted().map { community in
                    let indices = grouped[community]!
                    let unassigned = community == "__unassigned"
                    let classified = ClassificationMapProjection.region(community)
                    let provinceName = classified.map { overrides["province:\(community)"] ?? ($0.provinceName + "省") }
                        ?? (unassigned ? "待分区" : name(indices, level: .province, key: "province:\(community)", suffix: "省"))
                    let path = planetPath + [provinceName]
                    let indexByID = Dictionary(uniqueKeysWithValues: indices.map { (layout.nodes[$0].point.id, $0) })
                    var cityGroups: [(String?, [Int])] = []
                    if classified != nil {
                        let topics = Dictionary(grouping: indices) { index in
                            ClassificationMapProjection.region(geography[layout.nodes[index].point.id]?.communityID)?.topicName ?? "未细分"
                        }
                        if topics.keys.contains(where: { $0 != "未细分" }) {
                            cityGroups = topics.keys.sorted().map { (Optional($0), topics[$0]!) }
                        }
                    } else if !unassigned {
                        let groups = SemanticSubtopicEngine.partition(memberIDs: indices.map { layout.nodes[$0].point.id }, embeddings: embeddings)
                        if groups.count > 1 { cityGroups = groups.map { (nil, $0.compactMap { indexByID[$0] }) } }
                    }
                    let cities: [EvaluationProvince] = cityGroups.map { topic, cityIndices in
                        let key = topic.map { "topic:" + Data($0.utf8).base64EncodedString() }
                            ?? "semantic-city:" + identity(cityIndices, level: "city").components(separatedBy: ":").last!
                        let cityKey = "province:\(community)/" + key
                        let cityName = topic.map { overrides[cityKey] ?? ($0 + "市") }
                            ?? name(cityIndices, level: .city, key: cityKey, suffix: "市")
                        return EvaluationProvince(id: planetKey + "/" + cityKey, name: cityName,
                            members: members(cityIndices), level: "市", path: path + [cityName], mapLabelID: cityKey)
                    }
                    return EvaluationProvince(id: planetKey + "/province:\(community)", name: provinceName,
                        members: members(indices), level: "省", path: path, children: cities, mapLabelID: "province:\(community)")
                }
                return EvaluationProvince(id: planetKey, name: planet.name, members: members(planet.nodeIndices),
                    level: "行星", path: planetPath, children: provinces)
            }
            return EvaluationProvince(id: identity(system.nodeIndices, level: "system"), name: system.name,
                members: members(system.nodeIndices), level: "恒星系", path: systemPath, children: planets)
        }
        func refine(_ siblings: [EvaluationProvince], parentPath: [String]) -> [EvaluationProvince] {
            guard !siblings.isEmpty else { return [] }
            let level: AdministrativeLevel = siblings[0].level == "市" ? .city : .province
            let proposed = SemanticPlaceNameEngine.siblingNames(contents: siblings.map { $0.members.map(\.text) }, level: level)
            return siblings.enumerated().map { index, original in
                var scope = original
                if let key = scope.mapLabelID, !key.hasPrefix("province:classification:"), !scope.name.contains("待分区") {
                    let generated = proposed[index] + (scope.level == "省" ? "省" : "市")
                    scope.generatedName = generated
                    scope.name = overrides[key].flatMap { $0.isEmpty ? nil : $0 } ?? generated
                }
                scope.path = parentPath + [scope.name]
                scope.children = refine(scope.children, parentPath: scope.path)
                return scope
            }
        }
        return refine(built, parentPath: [])
    }
}

/// Shared by the rendered map and its evaluation browser: never partition after camera rotation.
private enum SemanticAdministrativeGeometry {
    static func position(id: PointID, geography: PointGeographyRecord?) -> Point3D {
        if let geography {
            let latitude = CGFloat(geography.latitude) * .pi / 180
            let longitude = CGFloat(geography.longitude) * .pi / 180
            return Point3D(x: cos(latitude) * sin(longitude), y: sin(latitude), z: cos(latitude) * cos(longitude))
        }
        let bytes = withUnsafeBytes(of: id.rawValue.uuid) { Array($0) }
        let radial = CGFloat((Int(bytes[0]) << 8) | Int(bytes[1])) / 65_535
        let bearing = CGFloat((Int(bytes[2]) << 8) | Int(bytes[3])) / 65_535 * 2 * .pi
        let angle = sqrt(radial) * 0.18
        return Point3D(x: sin(angle) * cos(bearing), y: sin(angle) * sin(bearing), z: cos(angle))
    }

    static func partitions(_ indices: [Int], bucketCount: Int, around center: Point3D, positions: [Point3D]) -> [(Int, [Int])] {
        guard bucketCount > 1 else { return [(0, indices)] }
        let east = Point3D(x: -center.z, y: 0, z: center.x).normalized
        let north = Point3D(x: center.y * east.z, y: center.z * east.x - center.x * east.z, z: -center.y * east.x).normalized
        let grouped = Dictionary(grouping: indices) { index -> Int in
            let point = positions[index]
            let bearing = atan2(point.x * east.x + point.y * east.y + point.z * east.z,
                                point.x * north.x + point.y * north.y + point.z * north.z)
            let normalized = (bearing + .pi) / (2 * .pi)
            return min(bucketCount - 1, max(0, Int(floor(normalized * CGFloat(bucketCount)))))
        }
        return grouped.keys.sorted().map { ($0, grouped[$0]!) }
    }
}

private struct EvaluationScopeBrowser: View {
    @EnvironmentObject private var container: AppContainer
    let nodes: [EvaluationProvince]
    let embeddings: [PointEmbeddingRecord]
    let reviewed: Set<String>
    var current: EvaluationProvince? = nil
    @State private var query = ""
    @State private var minimumCount = 0
    @State private var reviewFilter = "全部"
    @State private var selectedLevel = "逐级浏览"
    @State private var sort = "内容最多"
    @State private var latestReviewed: Set<String> = []

    private func flatten(_ values: [EvaluationProvince]) -> [EvaluationProvince] {
        values.flatMap { [$0] + flatten($0.children) }
    }

    private var visible: [EvaluationProvince] {
        let all = selectedLevel == "逐级浏览" ? nodes : flatten(nodes).filter { $0.level == selectedLevel }
        let ids = reviewed.union(latestReviewed)
        return all.filter { node in
            let scopes = flatten([node])
            let hasReviewed = scopes.contains { ids.contains($0.id) }
            let hasUnreviewed = scopes.contains { !ids.contains($0.id) }
            let matchReview = reviewFilter == "全部" || (reviewFilter == "含已评估" ? hasReviewed : hasUnreviewed)
            return node.members.count >= minimumCount && matchReview && (query.isEmpty
                || (node.path + [node.name]).joined(separator: " / ").localizedCaseInsensitiveContains(query)
                || node.members.contains { $0.text.localizedCaseInsensitiveContains(query) }
                || scopes.contains { $0.name.localizedCaseInsensitiveContains(query) })
        }.sorted {
            if sort == "名称" { return $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
            return $0.members.count == $1.members.count ? $0.id < $1.id : $0.members.count > $1.members.count
        }
    }

    var body: some View {
        List {
            Section {
                Text(container.storageMode == .test ? "独立测试数据库" : "正式数据库").font(.caption)
                Text("恒星系 → 行星 → 省 → 市 → Point；可评估任一级，建议不会自动改图。")
                    .font(.caption).foregroundStyle(.secondary)
                if let current {
                    Text(current.path.joined(separator: " › ")).font(.caption).foregroundStyle(.secondary)
                    NavigationLink("评估整个\(current.level)（\(current.members.count)条）") {
                        ProvinceEvaluationDetailView(province: current, embeddings: embeddings)
                    }
                }
                Picker("查看层级", selection: $selectedLevel) {
                    ForEach(["逐级浏览", "恒星系", "行星", "省", "市"], id: \.self) { Text($0) }
                }
                Picker("评估状态", selection: $reviewFilter) {
                    ForEach(["全部", "含已评估", "含未评估"], id: \.self) { Text($0) }
                }
                Text("筛选作用于当前区域的下级；含已／未评估也检查其后代，保留可继续进入的路径。")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("至少包含", selection: $minimumCount) {
                    Text("不限数量").tag(0)
                    ForEach([2, 5, 10, 20, 50], id: \.self) { Text("\($0)条 Point").tag($0) }
                }
                Picker("排序", selection: $sort) { Text("内容最多").tag("内容最多"); Text("名称").tag("名称") }
            }
            Section("\(visible.count) 个结果") {
                if visible.isEmpty { Text("没有符合条件的区域，请调整筛选；没有地理坐标的内容列在行星的待分区中。") }
                ForEach(visible) { node in
                    NavigationLink {
                        if node.children.isEmpty {
                            ProvinceEvaluationDetailView(province: node, embeddings: embeddings)
                        } else {
                            EvaluationScopeBrowser(nodes: node.children, embeddings: embeddings,
                                reviewed: reviewed.union(latestReviewed), current: node)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(node.name) · \(node.level)")
                            Text("\(node.members.count) 条 Point · \(node.children.count) 个下级 · \(reviewed.union(latestReviewed).contains(node.id) ? "已评估" : "未评估")")
                                .font(.caption).foregroundStyle(.secondary)
                            if selectedLevel != "逐级浏览" {
                                Text(node.path.dropLast().joined(separator: " › ")).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(current?.name ?? "分层质量评估")
        .macSafeSearchable(text: $query, prompt: "筛选区域名称或 Point 内容")
        .onAppear { Task { latestReviewed = (try? await container.database.evaluatedScopeIDs()) ?? [] } }
    }
}

private struct ProvinceEvaluationDetailView: View {
    @EnvironmentObject private var container: AppContainer
    let province: EvaluationProvince
    let embeddings: [PointEmbeddingRecord]
    @State private var metrics: ProvinceQualityMetrics?
    @State private var showMetrics = false
    @State private var verdict = "暂时无法判断"
    @State private var humanScore = 0
    @State private var annotations: [String: String] = [:]
    @State private var pairAnnotations: [String: String] = [:]
    @State private var note = ""
    @State private var reports: [String] = []
    @State private var models: [String] = []
    @State private var decision = "尚未处理"
    @State private var evaluatedCount = 0
    @State private var evaluating = false
    @State private var saving = false
    @State private var history: [ProvinceEvaluation] = []
    @State private var message: String?
    private let verdicts = ["主题集中", "大体合理", "明显混杂", "暂时无法判断"]
    private let labels = ["未标注", "属于这里", "也属于别处", "应该移走", "不确定"]

    var body: some View {
        List {
            Section("人工判断 · 可先盲评") {
                Text(province.path.joined(separator: " › ")).font(.caption).foregroundStyle(.secondary)
                if province.id.contains("memory-fixture:") {
                    Text("这是回忆流程的人工合成向量样本，不能用于评价 E5 模型准确度。")
                        .font(.caption).foregroundStyle(.orange)
                }
                Picker("\(province.level)评价", selection: $verdict) { ForEach(verdicts, id: \.self) { Text($0) } }
                Picker("人工质量分", selection: $humanScore) {
                    Text("暂不打分").tag(0)
                    ForEach(1...5, id: \.self) { Text("\($0) 分").tag($0) }
                }
                Text("1分：明显混杂；3分：部分合理；5分：主题集中且归属合理。人工分不与余弦或 AI 意见混算。")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("判断理由或建议去向", text: $note, axis: .vertical)
                Toggle("显示算法证据", isOn: $showMetrics)
            }
            if showMetrics {
                Section("算法证据 · 原始余弦，不是正确率") {
                    if let metrics {
                        Text("有效向量 \(metrics.validMembers)/\(province.members.count)；区域内采样 \(metrics.sampledMembers)，区域外采样 \(metrics.sampledOutsiders)")
                        LabeledContent("区域内中位数", value: score(metrics.median))
                        LabeledContent("区域内 P10 / P90", value: "\(score(metrics.lowerDecile)) / \(score(metrics.upperDecile))")
                        LabeledContent("区域外中位数", value: score(metrics.outsideMedian))
                        LabeledContent("内外差值", value: score(metrics.median.flatMap { a in metrics.outsideMedian.map { a - $0 } }))
                        Text("\(metrics.pairCount) 对区域内比较。每侧最多128条，按稳定ID等距抽样。可疑标记仅表示：与区域外最相近项，比与区域内成员的中位相似度高0.05以上，不代表必须移走。区域外指整个数据库中不在当前范围的有效向量。")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(metrics.modelID).font(.caption2).textSelection(.enabled)
                    } else { ProgressView("计算中…") }
                }
            }
            Section("逐条判断") {
                ForEach(province.members, id: \.id) { member in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(member.text).textSelection(.enabled)
                        if showMetrics && metrics?.suspiciousIDs.contains(member.id) == true {
                            Label("值得复核", systemImage: "questionmark.circle").foregroundStyle(.orange)
                        }
                        Picker("归属判断", selection: Binding(
                            get: { annotations[member.id.rawValue.uuidString] ?? "未标注" },
                            set: { annotations[member.id.rawValue.uuidString] = $0 }
                        )) { ForEach(labels, id: \.self) { Text($0) } }
                    }
                }
            }
            if let metrics, !metrics.weakestPairs.isEmpty {
                Section("关系复核 · 采样内最弱的最多12对") {
                    Text("这是定向排查，不是随机准确率测试。可先判断关系，再展开算法证据查看数值。")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(metrics.weakestPairs) { pair in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(memberText(pair.a)).lineLimit(4)
                            Text("↕").foregroundStyle(.secondary)
                            Text(memberText(pair.b)).lineLimit(4)
                            if showMetrics { Text("原始余弦：\(score(pair.similarity))").font(.caption.monospacedDigit()) }
                            Picker("关系判断", selection: Binding(
                                get: { pairAnnotations[pair.id] ?? "未标注" },
                                set: { pairAnnotations[pair.id] = $0 }
                            )) {
                                ForEach(["未标注", "同一主题", "不同主题但有关联", "基本无关", "不确定"], id: \.self) { Text($0) }
                            }
                        }
                    }
                }
            }
            Section("AI 独立评估") {
                Text("使用模型页当前选择的语言模型。每次最多6条，每条最多320字符；只分析明确列出的片段。网络模型会发送这些片段，点击下方按钮表示同意。不会自动调整归属。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("已评估 \(evaluatedCount)/\(province.members.count) 条；分批意见不代表完整区域结论。")
                Button(evaluating ? "评估中…" : "评估下一批（最多6条）") { Task { await evaluateBatch() } }
                    .disabled(evaluating || evaluatedCount >= province.members.count)
                ForEach(reports.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("实际模型：\(models[index])").font(.caption).foregroundStyle(.secondary)
                        Text(reports[index]).textSelection(.enabled)
                    }
                }
                if !reports.isEmpty {
                    Picker("对以上建议的决定", selection: $decision) {
                        ForEach(["尚未处理", "接受建议（仅记录）", "驳回建议", "稍后处理"], id: \.self) { Text($0) }
                    }
                }
            }
            Section {
                Text("保存会保留本次成员原文、评分、模型与建议快照；下次保存会新增一份记录，不覆盖旧评估。离开前请保存。")
                    .font(.caption).foregroundStyle(.secondary)
                Button(saving ? "保存中…" : "保存本次评估快照") { Task { await save() } }
                    .disabled(saving || evaluating || metrics == nil)
                if let message { Text(message).font(.caption) }
            }
            Section("历史评估 · 保留当时内容") {
                ForEach(history) { record in
                    NavigationLink {
                        List {
                            Text(record.verdict)
                            Text((record.hierarchyPath ?? [record.provinceName]).joined(separator: " › ")).font(.caption)
                            Text("评估层级：\(record.scopeLevel ?? "省")").font(.caption)
                            if let score = record.humanScore { Text("人工质量分：\(score)/5") }
                            Text(record.note.isEmpty ? "未填写理由" : record.note)
                            Text(record.decision)
                            ForEach(record.members, id: \.id) { member in
                                VStack(alignment: .leading) {
                                    Text(member.text)
                                    Text(record.annotations[member.id.rawValue.uuidString] ?? "未标注").foregroundStyle(.secondary)
                                }
                            }
                            ForEach(record.aiReports.indices, id: \.self) { i in
                                Text("\(record.aiModels[i])\n\(record.aiReports[i])")
                            }
                            ForEach(record.metrics?.weakestPairs ?? []) { pair in
                                VStack(alignment: .leading) {
                                    Text(record.members.first(where: { $0.id == pair.a })?.text ?? "")
                                    Text("↕")
                                    Text(record.members.first(where: { $0.id == pair.b })?.text ?? "")
                                    Text("\(score(pair.similarity)) · \(record.pairAnnotations[pair.id] ?? "未标注")").font(.caption)
                                }
                            }
                            Text("\(record.version) · \(record.geographyVersion) · \(record.metrics?.modelID ?? "无向量指标")").font(.caption)
                            if let m = record.metrics {
                                Text("当时省内中位数 \(score(m.median)) · 省外 \(score(m.outsideMedian))")
                            }
                        }.navigationTitle(record.provinceName)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(record.createdAt, format: .dateTime.year().month().day().hour().minute())
                            Text("\(record.verdict) · \(record.members.count)条 · \(record.decision)").font(.caption)
                        }
                    }
                }
            }
        }
        .navigationTitle(province.name)
        .task {
            let ids = Set(province.members.map(\.id)), vectors = embeddings
            metrics = await Task.detached(priority: .userInitiated) {
                ProvinceQualityMetrics.compute(memberIDs: ids, embeddings: vectors, modelID: EmbeddingModelIdentity.multilingualE5Small)
            }.value
            do { history = try await container.database.provinceEvaluations(provinceID: province.id) }
            catch { message = "历史读取失败：\(error.localizedDescription)" }
        }
    }

    private func score(_ value: Double?) -> String { value.map { String(format: "%.3f", $0) } ?? "样本不足" }

    private func memberText(_ id: PointID) -> String {
        province.members.first(where: { $0.id == id })?.text ?? id.rawValue.uuidString
    }

    @MainActor private func evaluateBatch() async {
        evaluating = true
        defer { evaluating = false }
        let batch = Array(province.members.dropFirst(evaluatedCount).prefix(6))
        do {
            let reply = try await container.promptTranslator.evaluateProvince(name: province.name, members: batch, level: province.level)
            let evidence = batch.enumerated().map { "[\($0.offset + 1)] \($0.element.id.rawValue.uuidString)\n\(String($0.element.text.prefix(320)))" }.joined(separator: "\n")
            reports.append("输入范围：\(evaluatedCount + 1)–\(evaluatedCount + batch.count) / \(province.members.count)\n\(evidence)\n\nAI 建议：\n\(reply.text)")
            models.append(reply.modelID)
            evaluatedCount += batch.count
            message = "AI 评估尚未保存，请保存本次快照。"
        } catch { message = "AI 评估失败，未推进批次：\(error.localizedDescription)" }
    }

    @MainActor private func save() async {
        saving = true
        defer { saving = false }
        var record = ProvinceEvaluation(provinceID: province.id, provinceName: province.name, members: province.members,
                                       scopeLevel: province.level, hierarchyPath: province.path)
        record.verdict = verdict; record.annotations = annotations; record.note = note
        record.humanScore = humanScore == 0 ? nil : humanScore
        record.pairAnnotations = pairAnnotations
        record.aiReports = reports; record.aiModels = models; record.decision = decision; record.metrics = metrics
        do {
            try await container.database.saveProvinceEvaluation(record)
            history = try await container.database.provinceEvaluations(provinceID: province.id)
            message = "已保存。建议只记录，未改动地图或 Point。"
        } catch { message = "保存失败：\(error.localizedDescription)" }
    }
}

/// A system-UI globe: semantic positions are placed on a unit sphere and then
/// rendered with an orthographic projection. This avoids a GPU 3D engine while
/// preserving latitude, longitude, rotation and back-face occlusion.
struct GlobeMapView: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.appLanguage) private var appLanguage
    @State private var layout = StarLayout(nodes: [], links: [], embeddingCount: 0)
    @State private var entries: [PointMapEntry] = []
    @State private var geographies: [PointID: PointGeographyRecord] = [:]
    @State private var contentByPointID: [PointID: String] = [:]
    @State private var selected: PointSummary?
    @State private var loadFailed = false
    @State private var showingDemo = false
    @State private var isRecalculating = false
    @State private var pendingSemanticCount = 0
    @State private var showingSearch = false
    @State private var focusRequest: PointMapFocusRequest?

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
                SemanticGlobe(layout: layout, geographies: geographies,
                              contentByPointID: contentByPointID, focusRequest: focusRequest) { selected = $0 }
            }
        }
        .navigationTitle(AppLocalization.string("语义星球", language: appLanguage))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(Color(red: 0.02, green: 0.08, blue: 0.16), for: .navigationBar)
        .toolbar {
            Button { showingSearch = true } label: { Image(systemName: "magnifyingglass") }
                .tint(.white)
                .accessibilityLabel("搜索 Point")
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
        .sheet(isPresented: $showingSearch) {
            PointMapSearchSheet(entries: entries) { pointID in
                focusRequest = PointMapFocusRequest(pointID: pointID)
                showingSearch = false
            }
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
            self.entries = semanticEntries
            pendingSemanticCount = loadedEntries.count - semanticEntries.count
            let previous = discardingSavedCoordinates ? [] : try await storedGeographies
            let generated = await Task.detached(priority: .userInitiated) {
                SemanticGeographyEngine.make(embeddings: loadedEmbeddings, previous: previous)
            }.value
            PointVerseLog.embedding.info("Globe reload entries=\(loadedEntries.count, privacy: .public) embeddings=\(loadedEmbeddings.count, privacy: .public) pending=\(pendingSemanticCount, privacy: .public) communities=\(Set(generated.compactMap(\.communityID)).count, privacy: .public)")
            let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.pointID, $0) })
            let generatedByID = Dictionary(uniqueKeysWithValues: generated.map { ($0.pointID, $0) })
            if previousByID != generatedByID {
                try await container.database.saveGeographies(generated)
            }
            layout = StarLayoutEngine.makeGlobe(
                entries: semanticEntries,
                embeddedPointIDs: embeddedPointIDs
            )
            geographies = Dictionary(uniqueKeysWithValues: generated.map { ($0.pointID, $0) })
            contentByPointID = Dictionary(uniqueKeysWithValues: semanticEntries.map { ($0.id, $0.content) })
        } catch {
            loadFailed = true
        }
    }
}

struct SemanticGlobe: View {
    private let minimumZoom: CGFloat = 0.325
    private let maximumZoom: CGFloat = 24
    let layout: StarLayout
    let focusRequest: PointMapFocusRequest?
    let onSelect: (PointSummary) -> Void
    let onZoomOut: (() -> Void)?
    let showsChrome: Bool
    let externalZoom: CGFloat?
    let onZoomChanged: ((CGFloat) -> Void)?
    let planetTint: Color
    let cameraDriven: Bool
    let embeddedInUniverse: Bool
    let detailZoomOverride: CGFloat?
    let onCameraMagnificationChanged: ((CGFloat) -> Void)?
    let onCameraMagnificationEnded: (() -> Void)?
    let onInteractionBegan: (() -> Void)?
    private let topicByPointID: [PointID: String]
    private let communityByPointID: [PointID: String]
    private let contentByPointID: [PointID: String]
    private let spherePositions: [Point3D]
    private let semanticScopes: [EvaluationProvince]?

    @State private var orientation = Rotation3D.camera(yaw: 0.35, pitch: -0.18)
    @State private var dragOrigin: CGPoint?
    @State private var rotationOrigin: Rotation3D?
    @State private var zoom: CGFloat = 1
    @State private var zoomOrigin: CGFloat?
    @State private var showingRegions = false
    @State private var showsGeography = true
    @State private var cachedAdministrativeLabels: [AdministrativeLabel] = []
    @State private var placeNameOverrides: [String: String]
    @State private var focusedPointID: PointID?

    init(
        layout: StarLayout,
        geographies: [PointID: PointGeographyRecord],
        semanticScopes: [EvaluationProvince]? = nil,
        contentByPointID: [PointID: String] = [:],
        topicByPointID: [PointID: String] = [:],
        initialYaw: CGFloat = 0.35,
        initialZoom: CGFloat = 1,
        focusRequest: PointMapFocusRequest? = nil,
        onZoomOut: (() -> Void)? = nil,
        showsChrome: Bool = true,
        externalZoom: CGFloat? = nil,
        onZoomChanged: ((CGFloat) -> Void)? = nil,
        planetTint: Color = .cyan,
        cameraDriven: Bool = false,
        embeddedInUniverse: Bool = false,
        detailZoomOverride: CGFloat? = nil,
        onCameraMagnificationChanged: ((CGFloat) -> Void)? = nil,
        onCameraMagnificationEnded: (() -> Void)? = nil,
        onInteractionBegan: (() -> Void)? = nil,
        onSelect: @escaping (PointSummary) -> Void
    ) {
        self.layout = layout
        self.semanticScopes = semanticScopes
        self.focusRequest = focusRequest
        self.onSelect = onSelect
        self.onZoomOut = onZoomOut
        self.showsChrome = showsChrome
        self.externalZoom = externalZoom
        self.onZoomChanged = onZoomChanged
        self.planetTint = planetTint
        self.cameraDriven = cameraDriven
        self.embeddedInUniverse = embeddedInUniverse
        self.detailZoomOverride = detailZoomOverride
        self.onCameraMagnificationChanged = onCameraMagnificationChanged
        self.onCameraMagnificationEnded = onCameraMagnificationEnded
        self.onInteractionBegan = onInteractionBegan
        self.topicByPointID = topicByPointID
        self.communityByPointID = geographies.compactMapValues { value -> String? in
            guard let id = value.communityID else { return nil }
            return ClassificationMapProjection.region(id)?.provinceCommunityID ?? id
        }
        self.contentByPointID = contentByPointID
        _orientation = State(initialValue: .camera(yaw: initialYaw, pitch: -0.18))
        _zoom = State(initialValue: initialZoom)
        _placeNameOverrides = State(initialValue: Self.loadPlaceNameOverrides())
        self.spherePositions = layout.nodes.map {
            SemanticAdministrativeGeometry.position(id: $0.point.id, geography: geographies[$0.point.id])
        }
    }

    private var detailZoom: CGFloat { detailZoomOverride ?? zoom }

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

                if showsChrome { VStack(spacing: 0) {
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
                } }
            }
        }
        .sheet(isPresented: $showingRegions) {
            NavigationStack {
                List {
                    Section("知识地图") {
                        NavigationLink("分层质量评估") { ProvinceEvaluationIndexView() }
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
        .onChange(of: externalZoom) { _, value in
            guard let value else { return }
            zoom = min(maximumZoom, max(minimumZoom, value))
        }
        .onAppear {
            if cachedAdministrativeLabels.isEmpty {
                cachedAdministrativeLabels = makeAdministrativeLabels()
            }
            if focusRequest != nil { focus(on: focusRequest) }
        }
        .onChange(of: layout.nodes.count) { _, _ in
            cachedAdministrativeLabels = makeAdministrativeLabels()
        }
        .onChange(of: semanticScopes?.flatMap { [$0.id + $0.name] + $0.children.map { $0.id + $0.name } }) { _, _ in
            cachedAdministrativeLabels = makeAdministrativeLabels()
        }
        .onChange(of: placeNameOverrides) { _, overrides in
            Self.savePlaceNameOverrides(overrides)
        }
        .onChange(of: focusRequest) { _, request in
            focus(on: request)
        }
    }

    private func focus(on request: PointMapFocusRequest?) {
        guard let request,
              let index = layout.nodes.firstIndex(where: { $0.point.id == request.pointID }) else { return }
        let position = spherePositions[index]
        let targetYaw = atan2(-position.x, position.z)
        let rotatedDepth = -position.x * sin(targetYaw) + position.z * cos(targetYaw)
        let targetPitch = atan2(position.y, rotatedDepth)
        focusedPointID = request.pointID
        withAnimation(.easeInOut(duration: 0.6)) {
            orientation = .camera(yaw: targetYaw, pitch: targetPitch)
            zoom = min(maximumZoom, max(zoom, 12))
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
                if cameraDriven { onInteractionBegan?() }
                if dragOrigin == nil {
                    if !cameraDriven { onInteractionBegan?() }
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
                if cameraDriven {
                    onInteractionBegan?()
                    onCameraMagnificationChanged?(value)
                } else {
                    if zoomOrigin == nil { zoomOrigin = zoom }
                    zoom = min(maximumZoom, max(minimumZoom, (zoomOrigin ?? zoom) * value))
                    onZoomChanged?(zoom)
                }
            }
            .onEnded { value in
                let shouldExit = !cameraDriven && value < 0.82 && zoom <= minimumZoom + 0.03
                zoomOrigin = nil
                if shouldExit { onZoomOut?() }
                if cameraDriven { onCameraMagnificationEnded?() }
            }
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
        if factor < 1, zoom <= minimumZoom + 0.03, let onZoomOut {
            onZoomOut()
            return
        }
        withAnimation(.easeInOut(duration: 0.22)) {
            zoom = min(maximumZoom, max(minimumZoom, zoom * factor))
            onZoomChanged?(zoom)
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
                Gradient(colors: [planetTint.opacity(0.28), planetTint.opacity(0.12), Color.black.opacity(0.88)]),
                center: CGPoint(x: geometry.center.x - geometry.radius * 0.28, y: geometry.center.y - geometry.radius * 0.3),
                startRadius: 2,
                endRadius: geometry.radius * 1.2
            )
        )
        context.stroke(Path(ellipseIn: globeRect), with: .color(planetTint.opacity(0.58)), lineWidth: 1.4)

        if showsGeography {
            drawSemanticLand(context: &context, geometry: geometry)
        }
        drawGraticule(context: &context, geometry: geometry)
        if !embeddedInUniverse || detailZoom >= 0.85 {
            drawCoordinateLabels(context: &context, geometry: geometry)
            drawPoleLabels(context: &context, geometry: geometry)
        }

        let projected = projectedNodes(geometry: geometry)
        let clusters = displayClusters(projected: projected, geometry: geometry)

        if !embeddedInUniverse || detailZoom >= 0.65 {
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
            if focusedPointID == layout.nodes[nodeIndex].point.id {
                context.stroke(Path(ellipseIn: rect.insetBy(dx: -10, dy: -10)),
                               with: .color(.yellow.opacity(0.95)), lineWidth: 3)
            }

            let pointLabelThreshold: CGFloat = embeddedInUniverse ? 2.4 : 10
            let expandedLabelThreshold: CGFloat = embeddedInUniverse ? 4.5 : 18
            if detailZoom >= pointLabelThreshold, !node.title.isEmpty {
                let characterLimit = detailZoom >= expandedLabelThreshold ? 56 : 28
                let content = String(node.title.prefix(characterLimit))
                let lines = max(1, min(3, Int(ceil(Double(content.count) / 14.0))))
                let bubbleWidth: CGFloat = detailZoom >= expandedLabelThreshold ? 190 : 150
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
        }

        if !embeddedInUniverse || detailZoom >= 0.85 {
            drawAdministrativeLabels(context: &context, geometry: geometry)
        }
    }

    private func drawAdministrativeLabels(context: inout GraphicsContext, geometry: GlobeGeometry) {
        let visibleLevel: AdministrativeLevel
        switch detailZoom {
        case ..<1.8: visibleLevel = .province
        case ..<5: visibleLevel = .city
        default: visibleLevel = semanticScopes == nil ? .district : .city
        }
        let matching = cachedAdministrativeLabels.filter { $0.level == visibleLevel }
        let labels = matching.isEmpty ? cachedAdministrativeLabels.filter { $0.level == .province } : matching
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
        if let semanticScopes {
            var result: [AdministrativeLabel] = []
            for province in semanticScopes {
                let indices = province.members.compactMap { indexByID[$0.id] }
                guard !indices.isEmpty, let key = province.mapLabelID else { continue }
                let community = key.replacingOccurrences(of: "province:", with: "")
                let color = Self.communityColor(community)
                result.append(.init(id: key, level: .province, defaultName: province.generatedName ?? province.name, center: meanPosition(indices), color: color))
                for city in province.children {
                    let cityIndices = city.members.compactMap { indexByID[$0.id] }
                    guard !cityIndices.isEmpty, let cityKey = city.mapLabelID else { continue }
                    result.append(.init(id: cityKey, level: .city, defaultName: city.generatedName ?? city.name, center: meanPosition(cityIndices), color: color))
                }
            }
            return result
        }
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
        SemanticAdministrativeGeometry.partitions(indices, bucketCount: bucketCount, around: center, positions: spherePositions)
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
            // An embedded planet never zooms itself when tapped. The user
            // controls distance only through the universe camera.
            if !cameraDriven {
                withAnimation(.easeInOut(duration: 0.28)) {
                    zoom = min(maximumZoom, max(1.12, zoom * 1.5))
                }
            }
        } else if let index = nearest.nodeIndices.first {
            onSelect(layout.nodes[index].point)
        }
    }

    /// Map-style clustering in spherical coordinates. Membership is calculated
    /// before camera rotation, so dragging the globe never changes a cluster.
    /// Zoom is the only input that controls when a cluster expands into leaves.
    private func displayClusters(projected: [GlobeNode], geometry: GlobeGeometry) -> [GlobeCluster] {
        // Keep clustering at every zoom level. The threshold represents a
        // stable minimum screen separation, so leaves appear only when there
        // is enough room instead of all being exposed at one magic zoom value.
        let angularDistance = max(0.002, 30 / max(geometry.radius, 1))
        var remaining = Set(layout.nodes.indices)
        let focusedIndex = focusedPointID.flatMap { id in layout.nodes.firstIndex { $0.point.id == id } }
        var result: [GlobeCluster] = []

        while let seed = remaining.min() {
            remaining.remove(seed)
            let seedPosition = spherePositions[seed]
            let neighbors = remaining.filter { candidate in
                seed != focusedIndex && candidate != focusedIndex
                    && sphericalAngle(seedPosition, spherePositions[candidate]) <= angularDistance
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
        if embeddedInUniverse {
            // In universe mode the container itself is the camera-projected
            // planet diameter. Do not reuse the standalone page's reserved
            // header/footer geometry or its 0.43 inset.
            return GlobeGeometry(
                center: CGPoint(x: size.width / 2, y: size.height / 2),
                radius: min(size.width, size.height) / 2
            )
        }
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
        score >= 0.75 ? .mint : score >= 0.55 ? .cyan : .indigo
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

enum AdministrativeLevel {
    case province
    case city
    case district
}

/// Generates a short, deterministic label from all content in a region.
/// This is the offline fallback while the compact generative Judge is not part
/// of the simplified app target. It never uses a single representative title.
enum SemanticPlaceNameEngine {
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
            if level == .province, let theme { return "\(theme.name)·\(first)" }
            if level == .district, let second = rankedDetails.dropFirst().first?.0, first != second {
                return String("\(first)·\(second)".prefix(8))
            }
            return String(first.prefix(7))
        }
        if let theme { return theme.name }
        return fallbackKeyword(documents) ?? "未命名"
    }

    /// Compare sibling evidence, rather than assigning every software group the
    /// same broad label. A repeated name is not evidence for merging groups.
    static func siblingNames(contents: [[String]], level: AdministrativeLevel) -> [String] {
        let documents = contents.map { $0.map { $0.lowercased() } }
        let vocabulary = Array(Set(details + themes.flatMap(\.evidence))).sorted()
        let counts = documents.map { group in
            Dictionary(uniqueKeysWithValues: vocabulary.map { term in
                (term, group.filter { $0.contains(term.lowercased()) }.count)
            })
        }
        var used = Set<String>()
        return contents.indices.map { index in
            let ranked = vocabulary.filter { (counts[index][$0] ?? 0) > 0 }.sorted { a, b in
                func score(_ word: String) -> Double {
                    let local = Double(counts[index][word] ?? 0) / Double(max(1, documents[index].count))
                    let others = counts.indices.filter { $0 != index }.map { Double(counts[$0][word] ?? 0) / Double(max(1, documents[$0].count)) }
                    let background = others.isEmpty ? 0 : others.reduce(0, +) / Double(others.count)
                    return local - background * 0.8 + Double(min(word.count, 6)) * 0.005
                }
                let left = score(a), right = score(b)
                return left == right ? a < b : left > right
            }
            let base = name(contents: contents[index], level: level)
            let candidates = ranked.map { word in
                level == .province ? "\(word)·\(base.components(separatedBy: "·").first ?? base)" : word
            }
            let combinations = ranked.prefix(4).flatMap { a in ranked.prefix(4).filter { $0 != a }.map { "\(a)·\($0)" } }
            let chosen = ([base] + candidates + combinations).first { !used.contains($0) } ?? base
            used.insert(chosen)
            return chosen
        }
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

struct PlanetDistributionDemoView: View {
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
                    let normalizedStrength = min(1, max(0, (strength - 0.38) / 0.62))
                    // Relative relevance, not raw E5 cosine, controls distance.
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
