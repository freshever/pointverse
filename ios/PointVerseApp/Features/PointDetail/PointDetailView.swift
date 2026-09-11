import PointVerseKit
import SwiftUI

struct PointDetailView: View {
    let point: PointSummary

    var body: some View {
        List {
            Section("原音") {
                Label("原音已保存", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("播放与转写详情将在 P0 的下一步接入。")
                    .foregroundStyle(.secondary)
            }
            Section("本地处理") {
                Text(point.transcriptState == "failed" ? "转写失败，原音仍在" : "等待本地转写")
            }
        }
        .navigationTitle(point.title.isEmpty ? String(localized: "语音想法") : point.title)
    }
}
