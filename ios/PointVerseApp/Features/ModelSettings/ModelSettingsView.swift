import SwiftUI

struct ModelSettingsView: View {
    @AppStorage("appLanguage") private var appLanguage = "system"
    @EnvironmentObject private var container: AppContainer

    var body: some View {
        List {
            Section {
                Picker(selection: $appLanguage) {
                    AppText("跟随系统").tag("system")
                    AppText("简体中文").tag("zh-Hans")
                    AppText("繁体中文").tag("zh-Hant")
                    AppText("英文").tag("en")
                    AppText("日文").tag("ja")
                } label: {
                    AppText("界面语言")
                }
            } header: {
                AppText("界面语言")
            }
            Section {
                ModelRow(
                    manager: container.modelDownloadManager,
                    name: "Whisper base Q5_1",
                    metadata: "≈ 59.7 MB · MIT",
                    explanation: "模型下载完成并通过 SHA-256 校验后才会启用。录音不会因为模型缺失而受影响。"
                )
            } header: {
                AppText("语音转写")
            }
            Section {
                ModelRow(
                    manager: container.qwenDownloadManager,
                    name: "Qwen3 0.6B Q8_0",
                    metadata: "≈ 639 MB · Apache-2.0",
                    explanation: "用于在设备端提炼标题、摘要和标签；不影响录音与语音转写。"
                )
            } header: {
                AppText("本地整理")
            }
        }
        .navigationTitle(AppLocalization.string("本地模型", language: appLanguage))
    }
}

private struct ModelRow: View {
    @ObservedObject var manager: ModelDownloadManager
    let name: String
    let metadata: String
    let explanation: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: name)
                    Text(verbatim: metadata)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                status
            }

            switch manager.state {
            case .downloading(let progress):
                ProgressView(value: progress)
                HStack {
                    Text(progress, format: .percent.precision(.fractionLength(0)))
                        .font(.caption).monospacedDigit()
                    Spacer()
                    Button(role: .cancel) { manager.cancel() } label: { AppText("取消下载") }
                }
            case .verifying:
                ProgressView().controlSize(.small)
            case .installed:
                Button(role: .destructive) { manager.remove() } label: { AppText("卸载模型") }
            case .failed:
                Button { manager.download() } label: { AppText("重新下载") }
            case .checking:
                ProgressView().controlSize(.small)
            case .notInstalled:
                Button { manager.download() } label: { AppText("下载模型") }
            }

            AppText(explanation)
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var status: some View {
        switch manager.state {
        case .checking: AppText("检查中")
        case .notInstalled: AppText("未安装")
        case .downloading: AppText("下载中")
        case .verifying: AppText("正在校验")
        case .installed: AppText("已安装").foregroundStyle(.green)
        case .failed(let error):
            AppText(error == .modelChecksumMismatch ? "校验失败" : error == .insufficientDiskSpace ? "空间不足" : "下载失败")
                .foregroundStyle(.red)
        }
    }
}
