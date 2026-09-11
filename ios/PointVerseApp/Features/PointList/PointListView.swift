import PointVerseKit
import SwiftUI

struct PointListView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var query = ""
    @State private var points: [PointSummary] = []
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if points.isEmpty {
                ContentUnavailableView("还没有想法", systemImage: "waveform", description: Text("保存第一条语音后会出现在这里"))
            } else {
                List(points) { point in
                    NavigationLink {
                        PointDetailView(point: point)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(point.title.isEmpty ? String(localized: "语音想法") : point.title).font(.headline)
                            Text(point.createdAt, format: .dateTime.month().day().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                            Text(point.transcriptState == "failed" ? "转写失败，原音仍在" : "等待本地转写")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("想法")
        .searchable(text: $query, prompt: "搜索转写、标题或摘要")
        .task(id: query) { await reload() }
        .refreshable { await reload() }
        .alert("无法读取本地资料", isPresented: .constant(errorMessage != nil)) {
            Button("好") { errorMessage = nil }
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
