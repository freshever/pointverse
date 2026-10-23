import PointVerseKit
import SwiftUI

struct PointListView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var query = ""
    @State private var points: [PointSummary] = []
    @State private var rediscoveryItems: [RediscoveryItem] = []
    @State private var errorMessage: String?
    @State private var speakers: [SpeakerProfile] = []
    @State private var recordingLabels: [PointID: RecordingLabels] = [:]
    @State private var speakerFilter: UUID?
    @State private var voiceFilter: RecordingVoiceState?

    private var filteredPoints: [PointSummary] {
        points.filter { point in
            (speakerFilter == nil || recordingLabels[point.id]?.speakerID == speakerFilter) &&
            (voiceFilter == nil || recordingLabels[point.id]?.voiceState == voiceFilter)
        }
    }
    @Environment(\.appLanguage) private var appLanguage

    var body: some View {
        Group {
            if points.isEmpty {
                ContentUnavailableView {
                    Label { AppText("还没有想法") } icon: { Image(systemName: "waveform") }
                } description: {
                    AppText("保存第一条语音后会出现在这里")
                }
            } else {
                List {
                    if !rediscoveryItems.isEmpty && speakerFilter == nil && voiceFilter == nil {
                        Section {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("思考回忆 · 今天", systemImage: "rectangle.stack.fill")
                                    .font(.title3.bold())
                                Text("看看以前留下的想法，今天能否再往前走一步。")
                                    .font(.subheadline).foregroundStyle(.secondary)
                                Text("\(rediscoveryItems.count) 条回忆 · 点开原文，选择相关内容接着想")
                                    .font(.caption).foregroundStyle(.indigo)
                            }.padding(.vertical, 8)
                            ForEach(rediscoveryItems) { item in
                                VStack(alignment: .leading, spacing: 10) {
                                    NavigationLink {
                                        PointDetailView(point: item.point)
                                            .task { try? await container.database.recordRediscoveryFeedback(pointID: item.id, feedback: .opened, context: "ideas") }
                                    } label: {
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(item.point.title.isEmpty ? "未命名想法" : item.point.title)
                                                .font(.headline)
                                            if !item.content.isEmpty {
                                                Text(item.content).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                                            }
                                            Label(rediscoveryReason(item), systemImage: item.reason == .relatedToRecent ? "link" : "clock.arrow.circlepath")
                                                .font(.caption).foregroundStyle(.indigo)
                                        }
                                    }
                                    HStack(spacing: 8) {
                                        feedbackButton("有用", icon: "hand.thumbsup", item: item, feedback: .useful)
                                        feedbackButton("稍后", icon: "clock", item: item, feedback: .later)
                                        feedbackButton("不相关", icon: "hand.thumbsdown", item: item, feedback: .notRelated)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    header: {
                        Label("回忆", systemImage: "sparkles")
                    } footer: {
                        Text("每天少量唤回旧想法；候选只是提示，不会自动判定关系。")
                    }
                    }
                    Section("全部想法") {
                        if speakerFilter != nil || voiceFilter != nil {
                            HStack {
                                Text([speakers.first(where: { $0.id == speakerFilter })?.name, voiceFilter?.title].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("清除筛选") { speakerFilter = nil; voiceFilter = nil }
                            }
                            if filteredPoints.isEmpty { Text("没有符合条件的录音").foregroundStyle(.secondary) }
                        }
                        ForEach(filteredPoints) { point in
                            NavigationLink {
                                PointDetailView(point: point)
                            } label: {
                                pointRow(point)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    Task {
                                        do { try await container.deletePoint(point.id) }
                                        catch { errorMessage = "移入回收站失败：\(error.localizedDescription)" }
                                        await reload()
                                    }
                                } label: {
                                    Label("移入回收站", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(AppLocalization.string("想法", language: appLanguage))
        .toolbar {
            NavigationLink { PointOrganizationView() } label: { Label("整理", systemImage: "tray.2") }
            Menu {
                Button("全部录音与想法") { speakerFilter = nil; voiceFilter = nil }
                Section("说话人") {
                    ForEach(speakers) { speaker in
                        Button(speaker.name) { speakerFilter = speaker.id }
                    }
                    Button("不限说话人") { speakerFilter = nil }
                }
                Section("声音状态") {
                    ForEach(RecordingVoiceState.allCases, id: \.rawValue) { state in
                        Button(state.title) { voiceFilter = state }
                    }
                    Button("不限声音状态") { voiceFilter = nil }
                }
            } label: { Image(systemName: speakerFilter == nil && voiceFilter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill") }
        }
        .macSafeSearchable(
            text: $query,
            prompt: AppLocalization.string("搜索转写、标题或摘要", language: appLanguage)
        )
        .task(id: query) { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: PointOrganization.didChange)) { _ in Task { await reload() } }
        .refreshable { await reload() }
        .alert(AppLocalization.string("无法读取本地资料", language: appLanguage), isPresented: .constant(errorMessage != nil)) {
            Button(AppLocalization.string("好", language: appLanguage)) { errorMessage = nil }
        }
    }

    private func reload() async {
        do {
            points = try await container.database.listPoints(matching: query)
            speakers = try await container.database.speakerProfiles()
            recordingLabels = Dictionary(uniqueKeysWithValues: try await container.database.recordingLabels().map { ($0.pointID, $0) })
            if let speakerFilter, !speakers.contains(where: { $0.id == speakerFilter }) { self.speakerFilter = nil }
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let items = try await container.database.rediscoveryItems(referenceDate: Date(), limit: 4)
                rediscoveryItems = items
                for item in items {
                    try? await container.database.recordRediscoveryFeedback(pointID: item.id, feedback: .shown, context: "ideas")
                }
            } else {
                rediscoveryItems = []
            }
        } catch {
            errorMessage = "请稍后重试"
        }
    }

    @ViewBuilder
    private func pointRow(_ point: PointSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(point.title.isEmpty ? "语音想法" : point.title).font(.headline)
            Text(point.createdAt, format: .dateTime.month().day().hour().minute())
                .font(.caption).foregroundStyle(.secondary)
            if let labels = recordingLabels[point.id] {
                Text([speakers.first(where: { $0.id == labels.speakerID })?.name, labels.voiceState == .unknown ? nil : labels.voiceState.title]
                    .compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.indigo)
            }
            if point.transcriptState == "text" {
                AppText("文本 Point").font(.caption).foregroundStyle(.secondary)
            } else if point.transcriptState == "failed" {
                AppText("转写失败，原音仍在").font(.caption).foregroundStyle(.secondary)
            } else {
                AppText("等待本地转写").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func rediscoveryReason(_ item: RediscoveryItem) -> String {
        if let related = item.relatedPoint {
            return "与最近的「\(related.title.isEmpty ? "未命名想法" : related.title)」可能相关"
        }
        return "一条超过 7 天没有回看的想法"
    }

    private func feedbackButton(_ title: String, icon: String, item: RediscoveryItem,
                                feedback: RediscoveryFeedback) -> some View {
        Button {
            rediscoveryItems.removeAll { $0.id == item.id }
            Task { try? await container.database.recordRediscoveryFeedback(pointID: item.id, feedback: feedback, context: "ideas") }
        } label: {
            Label(title, systemImage: icon)
        }
    }
}

struct PointOrganizationView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var records: [PointOrganizationRecord] = []
    @State private var classifications: [PointID: PointFacetClassification] = [:]
    @State private var dimension: PointFacetDimension = .domain
    @State private var candidates: [PointCleanupCandidate] = []
    @State private var selectedCleanup: Set<PointID> = []
    @State private var trashCount = 0
    @State private var loading = true
    @State private var busy = false
    @State private var scanTask: Task<Void, Never>?
    @State private var batchTask: Task<Void, Never>?
    @State private var completed = 0
    @State private var total = 0
    @State private var status = ""
    @State private var error: String?
    @State private var confirmReorganize = false
    @State private var confirmTrash = false
    @State private var cleanupLimit = 50

    private var usesModel: Bool { dimension == .domain || dimension == .topic }
    private var grouped: [(id: String, members: [PointOrganizationRecord])] {
        var groups: [String: [PointOrganizationRecord]] = [:]
        for record in records {
            let values = classifications[record.id]?.values[dimension] ?? []
            for id in values.isEmpty ? Set([PointFacetEngine.unassigned]) : values {
                groups[id, default: []].append(record)
            }
        }
        return groups.map { (id: $0.key, members: $0.value) }.sorted {
            $0.members.count == $1.members.count ? $0.id < $1.id : $0.members.count > $1.members.count
        }
    }

    var body: some View {
        List {
            organizationSection
            cleanupSection
            Section {
                NavigationLink { PointTrashView() } label: { Label("回收站 · \(trashCount)条", systemImage: "trash") }
                Text("移入回收站不会删除原文、语音、图片、关系或分类。没有自动清空期限，随时可恢复。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if loading { ProgressView("读取当前资料库…") }
            if !status.isEmpty { Text(status).font(.callout) }
            if let error { Text(error).foregroundStyle(.red) }
            groupsSection
        }
        .navigationTitle("整理")
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: PointOrganization.didChange)) { _ in
            Task { await reload() }
        }
        .onDisappear { batchTask?.cancel(); scanTask?.cancel() }
        .confirmationDialog("重新整理全部\(records.count)条内容？", isPresented: $confirmReorganize, titleVisibility: .visible) {
            Button("开始重新整理") { startReorganization() }
            Button("取消", role: .cancel) { }
        } message: {
            Text(usesModel
                 ? "将重新提取全部内容的主题与知识领域，包括已经整理过的记录。人工分类不覆盖；网络模型会发送每条前600字符，可能产生费用，沿用现有网络授权。失败时保留原分类。"
                 : "按当前\(dimension.title)重新组织全部内容，不调用模型。表达性质按本地规则识别；项目只保留人工指定，不猜测项目。")
        }
        .confirmationDialog("将选中的\(selectedCleanup.count)条移入回收站？", isPresented: $confirmTrash, titleVisibility: .visible) {
            Button("移入回收站", role: .destructive) { moveSelectedToTrash() }
            Button("取消", role: .cancel) { }
        } message: { Text("这是你确认后的可恢复操作，不会永久删除附件。预览后内容已改变的记录会跳过。范围仅为当前资料库。") }
    }

    private var organizationSection: some View {
        Section("全部重新整理") {
            Text(container.storageMode == .test ? "当前：独立测试资料库" : "当前：正式资料库").font(.headline)
            Text("共\(records.count)条，不受想法列表的搜索或筛选限制。人工分类始终优先。")
                .font(.caption).foregroundStyle(.secondary)
            Picker("整理维度", selection: $dimension) {
                ForEach(PointFacetDimension.allCases, id: \.self) { Text($0.title).tag($0) }
            }.disabled(busy)
            Text(usesModel ? "知识领域和主题一起由当前文本模型重新提取，并同步脑图与宇宙。"
                 : (dimension == .project ? "项目属于人工信息，只按已指定项目重新分组，不会替你编造项目。" : "按问题、设想、计划、观察、方法、感受等本地关键词规则重新分组，不是模型判断。"))
                .font(.caption).foregroundStyle(.secondary)
            if busy {
                ProgressView(value: Double(completed), total: Double(max(1, total)))
                if batchTask != nil { Button("停止后续整理", role: .cancel) { batchTask?.cancel() } }
            } else {
                Button("全部重新整理") { confirmReorganize = true }.disabled(loading || records.isEmpty || scanTask != nil)
            }
        }
    }

    private var cleanupSection: some View {
        Section("清理候选 · 由你判断") {
            Text("仅本地检查完全重复的文字、无文字且无附件的记录。保留较早的重复项；有语音、图片或后续对话的内容不自动列入。短句和未分类不等于无意义。")
                .font(.caption).foregroundStyle(.secondary)
            Button("查找清理候选") {
                scanTask = Task { @MainActor in
                    guard await reload() else { scanTask = nil; return }
                    guard !Task.isCancelled else { return }
                    let snapshot = records
                    candidates = await Task.detached { PointOrganization.cleanupCandidates(snapshot) }.value
                    selectedCleanup = []; cleanupLimit = 50
                    status = "发现\(candidates.count)条清理候选，尚未移动任何内容。"
                    scanTask = nil
                }
            }.disabled(loading || busy || scanTask != nil)
            if !candidates.isEmpty {
                Button(selectedCleanup.count == candidates.count ? "取消全选" : "选择全部候选") {
                    selectedCleanup = selectedCleanup.count == candidates.count ? [] : Set(candidates.map(\.id))
                }.disabled(busy)
                ForEach(Array(candidates.prefix(cleanupLimit))) { candidate in
                    HStack(alignment: .top) {
                        Button {
                            if !selectedCleanup.insert(candidate.id).inserted { selectedCleanup.remove(candidate.id) }
                        } label: {
                            Image(systemName: selectedCleanup.contains(candidate.id) ? "checkmark.circle.fill" : "circle")
                        }.buttonStyle(.plain).disabled(busy)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(displayTitle(candidate.record.entry)).font(.headline)
                            Text(candidate.record.entry.content).lineLimit(3)
                            Text(candidate.reason).font(.caption).foregroundStyle(.secondary)
                            NavigationLink("查看原文") { PointDetailView(point: candidate.record.entry.point) }
                        }
                    }
                }
                if candidates.count > cleanupLimit { Button("再显示50条") { cleanupLimit += 50 } }
                Button("移入回收站（\(selectedCleanup.count)条）", role: .destructive) { confirmTrash = true }
                    .disabled(selectedCleanup.isEmpty || busy)
            }
        }
    }

    private var groupsSection: some View {
        Section("按\(dimension.title)查看 · 多归属可能重复计数") {
            ForEach(grouped, id: \.id) { group in
                NavigationLink {
                    List(group.members) { record in
                        NavigationLink { PointDetailView(point: record.entry.point) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(displayTitle(record.entry))
                                Text(record.entry.content).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            }
                        }
                    }.navigationTitle(groupTitle(group.id))
                } label: {
                    HStack { Text(groupTitle(group.id)); Spacer(); Text("\(group.members.count)").foregroundStyle(.secondary) }
                }
            }
        }
    }

    private func displayTitle(_ entry: PointMapEntry) -> String {
        if !entry.point.title.isEmpty { return entry.point.title }
        return entry.content.isEmpty ? "空白记录" : String(entry.content.prefix(50))
    }
    private func groupTitle(_ id: String) -> String {
        if id == PointFacetEngine.unassigned { return "待整理" }
        return dimension == .project ? id : dimension == .domain ? LCCCatalog.friendlyTitle(id) : PointFacetEngine.title(id)
    }

    @discardableResult @MainActor private func reload() async -> Bool {
        do {
            let loaded = try await container.database.organizationRecords()
            let overrides = try await container.database.facetOverrides()
            let reviews = try await container.database.lccClassificationReviews()
            let classified = await Task.detached {
                let manual = Dictionary(grouping: overrides, by: \.pointID)
                let reviewByID = Dictionary(uniqueKeysWithValues: reviews.map { ($0.pointID, $0) })
                return Dictionary(uniqueKeysWithValues: loaded.map { record in
                    (record.id, PointFacetEngine.classify(record.entry, overrides: manual[record.id] ?? [], review: reviewByID[record.id]))
                })
            }.value
            guard !Task.isCancelled else { return false }
            records = loaded; classifications = classified
            trashCount = try await container.database.trashedPoints().count
            candidates = []; selectedCleanup = []; error = nil
        } catch { self.error = error.localizedDescription; loading = false; return false }
        loading = false
        return true
    }

    private func startReorganization() {
        guard !busy else { return }
        busy = true; completed = 0; total = records.count; error = nil
        let model = usesModel
        batchTask = Task { @MainActor in
            defer {
                busy = false; batchTask = nil
                NotificationCenter.default.post(name: ClassificationMapProjection.didChange, object: nil)
            }
            do {
                guard await reload() else { return }
                try Task.checkCancellation()
                if !model {
                    completed = records.count
                    status = "已按\(dimension.title)重新组织\(records.count)条内容，人工信息未改变。"
                    return
                }
                let snapshot = records
                total = snapshot.count
                var failed = 0, consecutiveFailures = 0, updated = 0, preserved = 0, skipped = 0
                for record in snapshot {
                    try Task.checkCancellation()
                    let manual = classifications[record.id]?.manualDimensions ?? []
                    if manual.contains(.domain) && manual.contains(.topic) {
                        preserved += 1; completed += 1; continue
                    }
                    status = "\(completed + 1)/\(total) · 重新提取主题…"
                    let review = try await container.analyzeLCC(record.entry, useJudge: true, persist: false) { message in
                        status = "\(completed + 1)/\(total) · \(message)"
                    }
                    try Task.checkCancellation()
                    if review.decision.status == .failed {
                        failed += 1; consecutiveFailures += 1
                    } else {
                        let saved = try await container.database.saveLCCClassificationReview(review,
                            expectedRevision: record.revision, notifyChange: false)
                        if saved { updated += 1 } else { skipped += 1 }
                        consecutiveFailures = 0
                    }
                    completed += 1
                    if consecutiveFailures >= 3 { break }
                }
                status = "已检查\(completed)/\(total)条，更新\(updated)条，保留人工分类\(preserved)条，跳过已变更\(skipped)条，失败\(failed)条（旧分类保留）。"
                    + (consecutiveFailures >= 3 ? "连续调用失败，已停止；请检查当前模型后重试。" : "脑图与宇宙同步更新。")
                await reload()
            } catch is CancellationError {
                status = "已停止后续整理；已完成的结果保留，尚未处理的内容不变。"
            } catch { self.error = error.localizedDescription }
        }
    }

    private func moveSelectedToTrash() {
        let requests = candidates.filter { selectedCleanup.contains($0.id) }.map {
            PointTrashRequest(pointID: $0.id, reason: $0.reason, expectedRevision: $0.record.revision)
        }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                let moved = try await container.database.moveToTrash(requests)
                status = "已移入回收站\(moved)条；已变更或已移走的记录跳过。可在回收站恢复。"
                await reload()
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct PointTrashView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var items: [TrashedPoint] = []
    @State private var error: String?
    @State private var restoring = false
    var body: some View {
        List {
            Section {
                Text(container.storageMode == .test ? "独立测试资料库的回收站" : "正式资料库的回收站")
                Text("所有原文、附件和分类都保留，不会自动清空。恢复后会重新出现在想法、回忆和宇宙中。")
                    .font(.caption).foregroundStyle(.secondary)
                if !items.isEmpty { Button("恢复全部（\(items.count)条）") { restore(items.map(\.id)) }.disabled(restoring) }
            }
            if let error { Text(error).foregroundStyle(.red) }
            if items.isEmpty { Text("回收站是空的").foregroundStyle(.secondary) }
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 7) {
                    Text(item.point.title.isEmpty ? "未命名记录" : item.point.title).font(.headline)
                    Text(item.reason).font(.caption).foregroundStyle(.secondary)
                    Text(item.trashedAt, format: .dateTime.month().day().hour().minute()).font(.caption)
                    DisclosureGroup("查看保留的文字") { TrashTextPreview(pointID: item.id) }
                    Button("恢复这条内容") { restore([item.id]) }.disabled(restoring)
                }
            }
        }
        .navigationTitle("回收站")
        .task { await reload() }
    }
    @MainActor private func reload() async {
        do { items = try await container.database.trashedPoints() }
        catch { self.error = error.localizedDescription }
    }
    private func restore(_ ids: [PointID]) {
        restoring = true
        Task { @MainActor in
            defer { restoring = false }
            do { try await container.restorePoints(ids); await reload() }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct TrashTextPreview: View {
    @EnvironmentObject private var container: AppContainer
    let pointID: PointID
    @State private var text = "读取中…"
    var body: some View {
        Text(text).font(.callout).textSelection(.enabled)
            .task {
                do {
                    let detail = try await container.database.pointDetail(id: pointID)
                    let original = detail.sourceText ?? detail.effectiveTranscript ?? ""
                    text = original.isEmpty ? "暂无文字。原语音和图片仍保留，恢复后可查看。" : original
                } catch { text = "读取失败，请稍后重试。" }
            }
    }
}

/// SwiftUI's search presentation still calls the removed UIScreen focus API
/// when an iPhone app runs on macOS. Use an in-page field there, while keeping
/// the native searchable presentation on iPhone and iPad.
private struct MacSafeSearchModifier: ViewModifier {
    @Binding var text: String
    let prompt: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if ProcessInfo.processInfo.isiOSAppOnMac {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(prompt, text: $text)
                        .textFieldStyle(.plain)
                    if !text.isEmpty {
                        Button { text = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal).padding(.vertical, 8)
                content
            }
        } else {
            content.searchable(text: $text, prompt: prompt)
        }
    }
}

extension View {
    func macSafeSearchable(text: Binding<String>, prompt: String) -> some View {
        modifier(MacSafeSearchModifier(text: text, prompt: prompt))
    }
}
