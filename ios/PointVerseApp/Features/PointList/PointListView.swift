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
                                        try? await container.deletePoint(point.id)
                                        await reload()
                                    }
                                } label: {
                                    Label(AppLocalization.string("删除", language: appLanguage), systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(AppLocalization.string("想法", language: appLanguage))
        .toolbar {
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
