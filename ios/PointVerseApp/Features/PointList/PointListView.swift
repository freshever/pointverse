import PointVerseKit
import SwiftUI

struct PointListView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var query = ""
    @State private var points: [PointSummary] = []
    @State private var errorMessage: String?
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
                List(points) { point in
                    NavigationLink {
                        PointDetailView(point: point)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            if point.title.isEmpty {
                                AppText("语音想法").font(.headline)
                            } else {
                                Text(verbatim: point.title).font(.headline)
                            }
                            Text(point.createdAt, format: .dateTime.month().day().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                            if point.transcriptState == "text" {
                                AppText("文本 Point").font(.caption).foregroundStyle(.secondary)
                            } else if point.transcriptState == "failed" {
                                AppText("转写失败，原音仍在").font(.caption).foregroundStyle(.secondary)
                            } else {
                                AppText("等待本地转写").font(.caption).foregroundStyle(.secondary)
                            }
                        }
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
        .navigationTitle(AppLocalization.string("想法", language: appLanguage))
        .searchable(text: $query, prompt: AppLocalization.string("搜索转写、标题或摘要", language: appLanguage))
        .task(id: query) { await reload() }
        .refreshable { await reload() }
        .alert(AppLocalization.string("无法读取本地资料", language: appLanguage), isPresented: .constant(errorMessage != nil)) {
            Button(AppLocalization.string("好", language: appLanguage)) { errorMessage = nil }
        }
    }

    private func reload() async {
        do {
            points = try await container.database.listPoints(matching: query)
        } catch {
            errorMessage = "请稍后重试"
        }
    }
}
