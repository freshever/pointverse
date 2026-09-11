import PointVerseKit
import PhotosUI
import SwiftUI
import UIKit

struct PointDetailView: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = AudioPlayerViewModel()
    @State private var detail: PointDetail?
    @State private var editedTranscript = ""
    @State private var isEditing = false
    @State private var isSaving = false
    @State private var isGeneratingTitle = false
    @State private var titleGenerationMessage: String?
    @State private var messages: [ConversationMessage] = []
    @State private var messageText = ""
    @State private var isReplying = false
    @State private var conversationFailed = false
    @State private var isPressingVoiceInput = false
    @State private var isRecordingVoiceInput = false
    @State private var isTranscribingVoiceInput = false
    @State private var voiceInputFailed = false
    @State private var confirmingDelete = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var pointImages: [LoadedPointImage] = []
    @State private var isAddingPhotos = false
    @State private var photoError = false
    @Environment(\.appLanguage) private var appLanguage
    let point: PointSummary

    var body: some View {
        let addPhotosTitle = AppLocalization.string("添加照片", language: appLanguage)
        List {
            Section {
                if !pointImages.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            ForEach(pointImages) { item in
                                ZStack(alignment: .topTrailing) {
                                    Image(uiImage: item.image)
                                        .resizable().scaledToFill()
                                        .frame(width: 150, height: 150).clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                    Button(role: .destructive) { removePhoto(item) } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, .black.opacity(0.65))
                                    }
                                    .padding(6).buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                PhotosPicker(selection: $selectedPhotos, maxSelectionCount: 10, matching: .images) {
                    Label(addPhotosTitle, systemImage: "photo.badge.plus")
                }
                .disabled(isAddingPhotos)
                if isAddingPhotos { HStack { ProgressView(); AppText("正在保存照片") } }
                if photoError { AppText("照片保存失败").font(.footnote).foregroundStyle(.red) }
            } header: { AppText("照片") }

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
                            isGeneratingTitle = true
                            titleGenerationMessage = nil
                            let generatedTitle = await container.transcriptionService.deriveTitle(
                                pointID: point.id,
                                languageIdentifier: appLanguage
                            )
                            await reload()
                            isGeneratingTitle = false
                            titleGenerationMessage = generatedTitle.map { "标题已重新生成：" + $0 }
                                ?? "标题生成失败，请确认 Qwen 模型已安装"
                        }
                    } label: {
                        if isGeneratingTitle {
                            HStack {
                                ProgressView().controlSize(.small)
                                AppText("正在使用 Qwen 生成标题")
                            }
                        } else {
                            AppText("重新生成标题")
                        }
                    }
                    .disabled(isGeneratingTitle)
                    if let titleGenerationMessage {
                        AppText(titleGenerationMessage)
                            .font(.footnote)
                            .foregroundStyle(titleGenerationMessage.hasPrefix("标题已重新生成：") ? .green : .red)
                    }
                } header: { AppText("本地整理") }
            }

            Section {
                ForEach(messages) { message in
                    HStack {
                        if message.role == "user" { Spacer(minLength: 32) }
                        Text(verbatim: message.text)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(message.role == "user" ? Color.indigo.opacity(0.14) : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                        if message.role != "user" { Spacer(minLength: 32) }
                    }
                }
                if isReplying {
                    HStack { ProgressView(); AppText("Qwen 正在回复") }
                }
                HStack {
                    TextField(AppLocalization.string("继续聊聊这个想法", language: appLanguage), text: $messageText, axis: .vertical)
                    ZStack {
                        Circle().fill(isRecordingVoiceInput ? Color.red : Color.secondary.opacity(0.14))
                        if isTranscribingVoiceInput {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "mic.fill")
                                .foregroundStyle(isRecordingVoiceInput ? .white : .primary)
                        }
                    }
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
                    .scaleEffect(isPressingVoiceInput ? 1.08 : 1)
                    .onLongPressGesture(minimumDuration: 0.18, maximumDistance: 60, pressing: handleVoiceInputPressing, perform: startVoiceInput)
                    .accessibilityLabel(AppLocalization.string("按住语音输入", language: appLanguage))
                    .disabled(isReplying || isTranscribingVoiceInput)
                    Button {
                        sendMessage()
                    } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .disabled(isReplying || messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if conversationFailed {
                    AppText("回复失败，请确认 Qwen 模型已安装").font(.footnote).foregroundStyle(.red)
                }
                if isRecordingVoiceInput {
                    AppText("松开转为文字").font(.footnote).foregroundStyle(.red)
                } else if voiceInputFailed {
                    AppText("语音输入识别失败").font(.footnote).foregroundStyle(.red)
                }
            } header: { AppText("对话") }
        }
        .navigationTitle(currentTitle.isEmpty ? AppLocalization.string("语音想法", language: appLanguage) : currentTitle)
        .task { await reload() }
        .onChange(of: selectedPhotos) { _, items in addPhotos(items) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) { confirmingDelete = true } label: { Image(systemName: "trash") }
            }
        }
        .confirmationDialog(AppLocalization.string("删除这条想法？", language: appLanguage), isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button(AppLocalization.string("删除", language: appLanguage), role: .destructive) {
                Task {
                    try? await container.deletePoint(point.id)
                    dismiss()
                }
            }
            Button(AppLocalization.string("取消", language: appLanguage), role: .cancel) {}
        } message: {
            AppText("原音、转写和对话都会被永久删除。")
        }
    }

    private var currentTitle: String {
        detail?.title ?? point.title
    }

    private func reload() async {
        guard let loaded = try? await container.database.pointDetail(id: point.id) else { return }
        detail = loaded
        messages = (try? await container.database.conversationMessages(pointID: point.id)) ?? []
        let storedImages = (try? await container.database.images(pointID: point.id)) ?? []
        var loadedImages: [LoadedPointImage] = []
        for stored in storedImages {
            guard let url = try? await container.imageBlobStore.url(for: stored.relativePath),
                  let image = UIImage(contentsOfFile: url.path) else { continue }
            loadedImages.append(LoadedPointImage(asset: stored, image: image))
        }
        pointImages = loadedImages
        if let url = try? await container.blobStore.url(for: loaded.audioRelativePath) {
            player.prepare(url: url)
        }
        if loaded.transcriptState == "queued" || loaded.transcriptState == "running" {
            try? await Task.sleep(for: .seconds(1))
            await reload()
        }
    }

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        messageText = ""
        isReplying = true
        conversationFailed = false
        Task {
            let succeeded = await container.conversationService.send(
                pointID: point.id,
                text: text,
                languageIdentifier: appLanguage == "system" ? Locale.current.identifier : appLanguage
            )
            if succeeded {
                _ = await container.transcriptionService.deriveTitle(
                    pointID: point.id,
                    languageIdentifier: appLanguage
                )
            }
            await reload()
            isReplying = false
            conversationFailed = !succeeded
        }
    }

    private func handleVoiceInputPressing(_ pressing: Bool) {
        isPressingVoiceInput = pressing
        if !pressing, isRecordingVoiceInput { finishVoiceInput() }
    }

    private func startVoiceInput() {
        let savedLocaleIdentifier = detail?.localeIdentifier ?? ""
        let localeIdentifier = !savedLocaleIdentifier.isEmpty
            ? savedLocaleIdentifier
            : (appLanguage == "system" ? Locale.current.identifier : appLanguage)
        voiceInputFailed = false
        Task {
            do {
                try await container.conversationVoiceInputService.start(localeIdentifier: localeIdentifier)
                isRecordingVoiceInput = true
                if !isPressingVoiceInput { finishVoiceInput() }
            } catch {
                isRecordingVoiceInput = false
                voiceInputFailed = true
            }
        }
    }

    private func finishVoiceInput() {
        guard isRecordingVoiceInput else { return }
        isRecordingVoiceInput = false
        isTranscribingVoiceInput = true
        Task {
            do {
                let text = try await container.conversationVoiceInputService.finish()
                messageText += (messageText.isEmpty ? "" : " ") + text
            } catch {
                voiceInputFailed = true
            }
            isTranscribingVoiceInput = false
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

    private func addPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        isAddingPhotos = true
        photoError = false
        Task {
            for item in items {
                do {
                    guard let source = try await item.loadTransferable(type: Data.self),
                          let uiImage = UIImage(data: source),
                          let data = uiImage.jpegData(compressionQuality: 0.9) else { throw PointVerseError.invalidModelOutput }
                    let id = UUID()
                    let stored = try await container.imageBlobStore.saveJPEG(data, assetID: id)
                    let recognized = try? await container.imageTextRecognizer.recognize(data: data, language: appLanguage)
                    let storedURL = try await container.imageBlobStore.url(for: stored.relativePath)
                    let visualDescription = try? await container.visionGenerator.describe(
                        imageURL: storedURL,
                        localeIdentifier: appLanguage == "system" ? Locale.current.identifier : appLanguage
                    )
                    let imageContext = [visualDescription, recognized]
                        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }.joined(separator: "\n")
                    do {
                        try await container.database.addImage(pointID: point.id, id: id, relativePath: stored.relativePath,
                                                              sha256: stored.sha256, byteCount: stored.byteCount,
                                                              recognizedText: imageContext.isEmpty ? nil : imageContext)
                    } catch {
                        try? await container.imageBlobStore.delete(relativePath: stored.relativePath)
                        throw error
                    }
                } catch { photoError = true }
            }
            selectedPhotos = []
            isAddingPhotos = false
            await reload()
        }
    }

    private func removePhoto(_ item: LoadedPointImage) {
        Task {
            guard let path = try? await container.database.removeImage(id: item.id) else { return }
            try? await container.imageBlobStore.delete(relativePath: path)
            await reload()
        }
    }

    private func duration(_ milliseconds: Int) -> String {
        let seconds = milliseconds / 1_000
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct LoadedPointImage: Identifiable {
    let asset: PointImage
    let image: UIImage
    var id: UUID { asset.id }
}
