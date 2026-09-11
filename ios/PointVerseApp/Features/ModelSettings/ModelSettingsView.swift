import SwiftUI

struct ModelSettingsView: View {
    var body: some View {
        List {
            Section("语音转写") {
                LabeledContent("Whisper base", value: "未安装")
                Text("没有模型时仍可录音、播放和搜索已有文字。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("本地整理") {
                LabeledContent("Qwen3 0.6B", value: "未安装")
            }
        }
        .navigationTitle("本地模型")
    }
}
