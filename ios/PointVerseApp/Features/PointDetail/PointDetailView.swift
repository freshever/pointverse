import PointVerseKit
import SwiftUI

struct PointDetailView: View {
    @EnvironmentObject private var container: AppContainer
    @StateObject private var player = AudioPlayerViewModel()
    @State private var detail: PointDetail?
    @State private var editedTranscript = ""
    @State private var isEditing = false
    @State private var isSaving = false
    @Environment(\.appLanguage) private var appLanguage
    let point: PointSummary

    var body: some View {
        List {
            Section {
                HStack {
                    Label { AppText("原音已保存") } icon: { Image(systemName: "checkmark.circle.fill") }
                        .foregroundStyle(.green)
                    Spacer()
                    if let detail {
                        Text(duration(detail.durationMilliseconds))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Button {
                    player.toggle()
                } label: {
                    if player.isPlaying {
                        Label { AppText("暂停") } icon: { Image(systemName: "pause.fill") }
                    } else {
                        Label { AppText("播放原音") } icon: { Image(systemName: "play.fill") }
                    }
                }
                .disabled(!player.isReady)
            } header: {
                AppText("原音")
            }

            Section {
                if let detail {
                    switch detail.transcriptState {
                    case "succeeded":
                        if isEditing {
                            TextEditor(text: $editedTranscript).frame(minHeight: 120)
                            Button { saveCorrection() } label: { AppText("保存修正") }
                                .disabled(isSaving || editedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        } else {
                            if let transcript = detail.effectiveTranscript {
                                Text(verbatim: transcript).textSelection(.enabled)
                            } else {
                                AppText("没有识别到文字")
                            }
                            Button {
                                editedTranscript = detail.effectiveTranscript ?? ""
                                isEditing = true
                            } label: { AppText("修正文字") }
                        }
                    case "running":
                        HStack { ProgressView(); AppText("正在设备端转写") }
                    case "failed":
                        if detail.transcriptErrorCode == PointVerseError.onDeviceRecognitionUnavailable.rawValue {
                            AppText("模拟器不支持设备端转写，请使用真机测试。原音仍已保存。")
                                .foregroundStyle(.secondary)
                        } else {
                            AppText("转写失败，原音仍在").foregroundStyle(.secondary)
                            Button { retryTranscription() } label: { AppText("重新转写") }
                        }
                    default:
                        HStack { ProgressView(); AppText("等待本地转写") }
                    }
                } else {
                    ProgressView()
                }
            } header: { AppText("转写文字") }

            Section {
                AppText("使用系统设备端语音识别，不上传录音。支持简体中文、繁体中文、英文和日文。")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: { AppText("识别方式") }

            if detail?.transcriptState == "succeeded" {
                Section {
                    Button {
                        Task {
                            await container.transcriptionService.deriveTitle(pointID: point.id)
                            await reload()
                        }
                    } label: {
                        AppText("使用 Qwen 生成标题")
                    }
                } header: { AppText("本地整理") }
            }
        }
        .navigationTitle(currentTitle.isEmpty ? AppLocalization.string("语音想法", language: appLanguage) : currentTitle)
        .task { await reload() }
    }

    private var currentTitle: String {
        detail?.title ?? point.title
    }

    private func reload() async {
        guard let loaded = try? await container.database.pointDetail(id: point.id) else { return }
        detail = loaded
        if let url = try? await container.blobStore.url(for: loaded.audioRelativePath) {
            player.prepare(url: url)
        }
        if loaded.transcriptState == "queued" || loaded.transcriptState == "running" {
            try? await Task.sleep(for: .seconds(1))
            await reload()
        }
    }

    private func retryTranscription() {
        Task {
            await container.transcriptionService.transcribe(pointID: point.id)
            await reload()
        }
    }

    private func saveCorrection() {
        Task {
            isSaving = true
            try? await container.database.saveUserTranscript(pointID: point.id, userText: editedTranscript)
            isSaving = false
            isEditing = false
            await reload()
        }
    }

    private func duration(_ milliseconds: Int) -> String {
        let seconds = milliseconds / 1_000
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
