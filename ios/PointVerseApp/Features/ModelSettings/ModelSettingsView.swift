import PointVerseKit
import SwiftUI

struct ModelSettingsView: View {
    @AppStorage("appLanguage") private var appLanguage = "system"
    @AppStorage(ModelSelection.speechDefaultsKey) private var selectedSpeechModelID = ModelManifest.whisperBaseQ5.id
    @AppStorage(ModelSelection.languageDefaultsKey) private var selectedLanguageModelID = ModelManifest.qwen3_0_6BQ8.id
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
                } label: { AppText("界面语言") }
            } header: { AppText("界面语言") }

            Section {
                Picker(selection: $selectedSpeechModelID) {
                    ForEach(ModelSelection.speechModels, id: \.id) { manifest in
                        Text(verbatim: speechName(manifest)).tag(manifest.id)
                    }
                } label: { AppText("当前模型") }

                ForEach(container.speechModelManagers, id: \.manifest.id) { manager in
                    ModelRow(manager: manager, name: speechName(manager.manifest), metadata: metadata(manager.manifest), explanation: speechExplanation(manager.manifest), isSelected: selectedSpeechModelID == manager.manifest.id) {
                        selectedSpeechModelID = manager.manifest.id
                    }
                }
            } header: { AppText("语音转写") }

            Section {
                Picker(selection: $selectedLanguageModelID) {
                    AppText("关闭本地整理").tag(ModelSelection.disabledLanguageModelID)
                    ForEach(ModelSelection.languageModels, id: \.id) { manifest in
                        Text(verbatim: languageName(manifest)).tag(manifest.id)
                    }
                } label: { AppText("当前模型") }

                ForEach(container.languageModelManagers, id: \.manifest.id) { manager in
                    ModelRow(manager: manager, name: languageName(manager.manifest), metadata: metadata(manager.manifest), explanation: languageExplanation(manager.manifest), isSelected: selectedLanguageModelID == manager.manifest.id, onSelect: {
                        selectedLanguageModelID = manager.manifest.id
                    }, onInstalled: regenerateTitles)
                }
            } header: { AppText("本地整理") }
        }
        .navigationTitle(AppLocalization.string("本地模型", language: appLanguage))
        .onChange(of: selectedLanguageModelID) { _, _ in regenerateTitles() }
        .onChange(of: appLanguage) { _, _ in regenerateTitles() }
    }

    private func speechName(_ manifest: ModelManifest) -> String {
        switch manifest.id {
        case ModelManifest.whisperTinyQ5.id: return "Whisper tiny Q5_1"
        case ModelManifest.whisperSmallQ5.id: return "Whisper small Q5_1"
        default: return "Whisper base Q5_1"
        }
    }

    private func languageName(_ manifest: ModelManifest) -> String {
        manifest.id == ModelManifest.qwen3_1_7BQ8.id ? "Qwen3 1.7B Q8_0" : "Qwen3 0.6B Q8_0"
    }

    private func languageExplanation(_ manifest: ModelManifest) -> String {
        manifest.id == ModelManifest.qwen3_1_7BQ8.id
            ? "标题和对话质量更高，需要较新的设备并占用更多内存。"
            : "体积较小、速度较快，适合日常标题和简短对话。"
    }

    private func metadata(_ manifest: ModelManifest) -> String {
        ByteCountFormatter.string(fromByteCount: manifest.displayByteCount, countStyle: .file) + " · " + manifest.license
    }

    private func speechExplanation(_ manifest: ModelManifest) -> String {
        switch manifest.id {
        case ModelManifest.whisperTinyQ5.id: return "速度最快，适合短语音和较新的设备。"
        case ModelManifest.whisperSmallQ5.id: return "识别更准确，尤其适合英文，但速度较慢且占用更多内存。"
        default: return "速度与准确率较均衡，推荐大多数设备使用。"
        }
    }

    private func regenerateTitles() {
        Task { await container.transcriptionService.deriveMissingTitles(languageIdentifier: appLanguage) }
    }
}

private struct ModelRow: View {
    @Environment(\.appLanguage) private var appLanguage
    @ObservedObject var manager: ModelDownloadManager
    @State private var isShowingRemovalConfirmation = false
    let name: String
    let metadata: String
    let explanation: String
    let isSelected: Bool
    let onSelect: () -> Void
    var onInstalled: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: name)
                    Text(verbatim: metadata).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                status
            }

            switch manager.state {
            case .downloading(let progress):
                ProgressView(value: progress)
                HStack {
                    Text(progress, format: .percent.precision(.fractionLength(0))).font(.caption).monospacedDigit()
                    Spacer()
                    Button(role: .cancel) { manager.cancel() } label: { AppText("取消下载") }
                }
            case .verifying, .checking:
                ProgressView().controlSize(.small)
            case .installed:
                HStack {
                    selectButton
                    Spacer()
                    Button(role: .destructive) { isShowingRemovalConfirmation = true } label: { AppText("卸载模型") }
                        .buttonStyle(.borderless)
                }
            case .failed:
                Button { manager.download() } label: { AppText("重新下载") }
            case .notInstalled:
                Button { manager.download() } label: { AppText("下载模型") }
            }

            AppText(explanation).font(.footnote).foregroundStyle(.secondary)
        }
        .onChange(of: manager.state) { _, state in
            if state == .installed { onInstalled() }
        }
        .confirmationDialog(
            AppLocalization.string("确认卸载模型？", language: appLanguage),
            isPresented: $isShowingRemovalConfirmation,
            titleVisibility: .visible
        ) {
            Button(AppLocalization.string("卸载模型", language: appLanguage), role: .destructive) { manager.remove() }
            Button(AppLocalization.string("取消", language: appLanguage), role: .cancel) {}
        } message: {
            Text(verbatim: name)
        }
    }

    @ViewBuilder private var selectButton: some View {
        if isSelected {
            Label { AppText("使用中") } icon: { Image(systemName: "checkmark.circle.fill") }.foregroundStyle(.green)
        } else {
            Button(action: onSelect) { AppText("使用此模型") }
                .buttonStyle(.borderless)
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
            AppText(error == .modelChecksumMismatch ? "校验失败" : error == .insufficientDiskSpace ? "空间不足" : "下载失败").foregroundStyle(.red)
        }
    }
}
