import PointVerseKit
import PhotosUI
import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers

struct PointDetailView: View {
    private enum InputField: Hashable { case transcript, message }
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
    @State private var showingPhotoPicker = false
    @State private var showingCamera = false
    @State private var cropSource: PhotoCropSource?
    @State private var pointImages: [LoadedPointImage] = []
    @State private var isAddingPhotos = false
    @State private var photoError = false
    @State private var isAnalyzingPhotos = false
    @State private var visionAvailable = false
    @State private var visionAvailabilityChecked = false
    @State private var photoAnalysisKey: String?
    @State private var showingManifestation = false
    @Environment(\.appLanguage) private var appLanguage
    @FocusState private var focusedField: InputField?
    let point: PointSummary

    var body: some View {
        let addPhotosTitle = AppLocalization.string("添加照片", language: appLanguage)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                sourceMessage

                ForEach(timelineItems) { item in
                    switch item {
                    case .photo(let photo):
                        photoMessage(photo)
                    case .message(let message):
                        conversationMessage(message)
                    }
                }

                if isReplying {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        AppText("Qwen 正在回复")
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
                }

                operationStatus
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .scrollDismissesKeyboard(.interactively)
        .onTapGesture { focusedField = nil }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(currentTitle.isEmpty ? AppLocalization.string("语音想法", language: appLanguage) : currentTitle)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { composer(addPhotosTitle: addPhotosTitle) }
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("PointVersePointImagesDidChange"))) { notification in
            guard notification.object as? String == point.id.rawValue.uuidString else { return }
            Task { await reload() }
        }
        .onChange(of: selectedPhotos) { _, items in prepareCrop(items.first) }
        .photosPicker(
            isPresented: $showingPhotoPicker,
            selection: $selectedPhotos,
            maxSelectionCount: 1,
            matching: .images
        )
        .sheet(item: $cropSource) { source in
            SquarePhotoCropView(image: source.preview, onCancel: {
                cropSource = nil
                selectedPhotos = []
            }, onConfirm: { analysisData in
                cropSource = nil
                selectedPhotos = []
                addPhoto(sourceData: source.originalData, analysisData: analysisData)
            })
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraCaptureView { image in
                showingCamera = false
                prepareCapturedPhoto(image)
            } onCancel: {
                showingCamera = false
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showingManifestation) {
            PointManifestationView(pointID: point.id, sourceContext: manifestationContext) {
                showingManifestation = false
                Task { await reload() }
            }
            .environmentObject(container)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingManifestation = true } label: {
                    Label { AppText("显影") } icon: { Image(systemName: "wand.and.stars") }
                }
                .disabled(detail?.effectiveTranscript?.isEmpty != false && pointImages.isEmpty)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if detail?.transcriptState == "succeeded" {
                        Button(action: regenerateTitle) {
                            Label { AppText("重新生成标题") } icon: { Image(systemName: "sparkles") }
                        }
                        .disabled(isGeneratingTitle)
                    }
                    if !pointImages.isEmpty {
                        Button(action: analyzePhotos) {
                            Label { AppText("重新理解照片") } icon: { Image(systemName: "eye.circle") }
                        }
                        .disabled(isAnalyzingPhotos || !visionAvailable)
                    }
                    Divider()
                    Button(role: .destructive) { confirmingDelete = true } label: {
                        Label { AppText("删除") } icon: { Image(systemName: "trash") }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button { focusedField = nil } label: { AppText("完成") }
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

    private var sourceMessage: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 36, height: 36)
                        .background(Color.indigo, in: Circle())
                        .foregroundStyle(.white)
                }
                .disabled(!player.isReady)
                VStack(alignment: .leading, spacing: 2) {
                    AppText("原音已保存").font(.subheadline.weight(.medium))
                    if let detail {
                        Text(duration(detail.durationMilliseconds)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            Divider()
            transcriptContent
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder private var transcriptContent: some View {
        if let detail {
            switch detail.transcriptState {
            case "succeeded":
                if isEditing {
                    TextEditor(text: $editedTranscript).frame(minHeight: 110)
                        .focused($focusedField, equals: .transcript)
                    Button { saveCorrection() } label: { AppText("保存修正") }
                        .disabled(isSaving || editedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    Text(verbatim: detail.effectiveTranscript ?? AppLocalization.string("没有识别到文字", language: appLanguage))
                        .textSelection(.enabled)
                    Button {
                        editedTranscript = detail.effectiveTranscript ?? ""
                        isEditing = true
                    } label: { AppText("修正文字") }
                    .font(.footnote)
                }
            case "running":
                HStack { ProgressView(); AppText("正在设备端转写") }
            case "failed":
                AppText(detail.transcriptErrorCode == PointVerseError.onDeviceRecognitionUnavailable.rawValue
                        ? "模拟器不支持设备端转写，请使用真机测试。原音仍已保存。"
                        : "转写失败，原音仍在")
                    .foregroundStyle(.secondary)
                if detail.transcriptErrorCode != PointVerseError.onDeviceRecognitionUnavailable.rawValue {
                    Button { retryTranscription() } label: { AppText("重新转写") }
                }
            default:
                HStack { ProgressView(); AppText("等待本地转写") }
            }
        } else {
            ProgressView()
        }
    }

    private func photoMessage(_ item: LoadedPointImage) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .topTrailing) {
                Image(uiImage: item.image)
                    .resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                Button(role: .destructive) { removePhoto(item) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.65))
                }
                .padding(7).buttonStyle(.plain)
            }
            if let recognizedText = item.asset.recognizedText, !recognizedText.isEmpty {
                Text(verbatim: recognizedText)
                    .font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
            } else if visionAvailable || isAnalyzingPhotos {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    AppText("正在理解这张照片")
                }
                .font(.subheadline).foregroundStyle(.secondary)
            } else {
                AppText("尚未理解这张照片")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private func conversationMessage(_ message: ConversationMessage) -> some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 42) }
            Text(verbatim: message.text)
                .padding(.horizontal, 13).padding(.vertical, 10)
                .background(message.role == "user" ? Color.indigo.opacity(0.16) : Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 17))
                .textSelection(.enabled)
            if message.role != "user" { Spacer(minLength: 42) }
        }
    }

    @ViewBuilder private var operationStatus: some View {
        if isAddingPhotos { HStack { ProgressView(); AppText("正在保存照片") } }
        if photoError { AppText("照片保存失败").foregroundStyle(.red) }
        if isAnalyzingPhotos { HStack { ProgressView(); AppText("正在理解照片") } }
        if !pointImages.isEmpty && visionAvailabilityChecked && !visionAvailable {
            AppText("请先安装完整的 Qwen3-VL 和视觉投影模型").foregroundStyle(.orange)
        } else if let photoAnalysisKey {
            AppText(photoAnalysisKey).foregroundStyle(.secondary)
        }
        if isGeneratingTitle { HStack { ProgressView(); AppText("正在使用 Qwen 生成标题") } }
        if let titleGenerationMessage { AppText(titleGenerationMessage).foregroundStyle(.secondary) }
        if conversationFailed { AppText("回复失败，请确认 Qwen 模型已安装").foregroundStyle(.red) }
    }

    private func composer(addPhotosTitle: String) -> some View {
        let choosePhotosTitle = AppLocalization.string("从相册选择", language: appLanguage)
        return HStack(spacing: 9) {
            Menu {
                Button { showingCamera = true } label: {
                    Label { AppText("拍照") } icon: { Image(systemName: "camera") }
                }
                .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                Button { showingPhotoPicker = true } label: {
                    Label { Text(verbatim: choosePhotosTitle) } icon: { Image(systemName: "photo.on.rectangle") }
                }
            } label: {
                Label { AppText("Capture") } icon: { Image(systemName: "viewfinder.circle") }
                    .font(.subheadline.weight(.semibold))
            }
            .disabled(isAddingPhotos)
            .accessibilityLabel(addPhotosTitle)

            TextField(AppLocalization.string("继续聊聊这个想法", language: appLanguage), text: $messageText, axis: .vertical)
                .lineLimit(1...5)
                .focused($focusedField, equals: .message)

            Button(action: sendMessage) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                .disabled(isReplying || messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(.bar)
    }

    private func regenerateTitle() {
        Task {
            isGeneratingTitle = true
            titleGenerationMessage = nil
            let generatedTitle = await container.transcriptionService.deriveTitle(pointID: point.id, languageIdentifier: appLanguage)
            await reload()
            isGeneratingTitle = false
            titleGenerationMessage = generatedTitle.map { "标题已重新生成：" + $0 }
                ?? "标题生成失败，请确认 Qwen 模型已安装"
        }
    }

    private var currentTitle: String {
        detail?.title ?? point.title
    }

    private var timelineItems: [DetailTimelineItem] {
        let photos = pointImages.map(DetailTimelineItem.photo)
        let conversation = messages.map(DetailTimelineItem.message)
        return (photos + conversation).sorted { $0.createdAt < $1.createdAt }
    }

    private var manifestationContext: String {
        var parts: [String] = []
        if let transcript = detail?.effectiveTranscript, !transcript.isEmpty {
            parts.append("Voice note: " + String(transcript.prefix(700)))
        }
        let photos = pointImages.compactMap(\.asset.recognizedText).prefix(3).joined(separator: "\n")
        if !photos.isEmpty { parts.append("Photo context:\n" + String(photos.prefix(600))) }
        let discussion = messages.suffix(4).map { ($0.role == "user" ? "User: " : "Assistant: ") + String($0.text.prefix(180)) }.joined(separator: "\n")
        if !discussion.isEmpty { parts.append("Discussion:\n" + discussion) }
        return parts.joined(separator: "\n\n")
    }

    private func reload() async {
        guard let loaded = try? await container.database.pointDetail(id: point.id) else { return }
        detail = loaded
        messages = (try? await container.database.conversationMessages(pointID: point.id)) ?? []
        let storedImages = (try? await container.database.images(pointID: point.id)) ?? []
        var loadedImages: [LoadedPointImage] = []
        for stored in storedImages {
            guard let url = try? await container.imageBlobStore.url(for: stored.relativePath),
                  let data = try? Data(contentsOf: url),
                  let image = Self.thumbnail(from: data, maxPixelSize: 600) else { continue }
            loadedImages.append(LoadedPointImage(asset: stored, image: image))
        }
        let available = await container.visionGenerator.isAvailable()
        visionAvailable = available
        visionAvailabilityChecked = true
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

    private func prepareCrop(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let preview = Self.thumbnail(from: data, maxPixelSize: 2_048) else {
                photoError = true
                selectedPhotos = []
                return
            }
            cropSource = PhotoCropSource(originalData: data, preview: preview)
        }
    }

    private func prepareCapturedPhoto(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.95),
              let preview = Self.thumbnail(from: data, maxPixelSize: 2_048) else {
            photoError = true
            return
        }
        cropSource = PhotoCropSource(originalData: data, preview: preview)
    }

    private func addPhoto(sourceData source: Data, analysisData: Data) {
        isAddingPhotos = true
        photoError = false
        Task {
                do {
                    // The title/chat generator may still hold another GGUF model.
                    // Never keep it resident while loading the vision pipeline.
                    await container.transcriptionService.releaseLanguageModel()
                    guard let data = Self.compressedJPEG(from: source) else { throw PointVerseError.invalidModelOutput }
                    let id = UUID()
                    let stored = try await container.imageBlobStore.saveJPEG(data, assetID: id)
                    let recognized = try? await container.imageTextRecognizer.recognize(data: data, language: appLanguage)
                    let visualDescription: String?
                    do {
                        visualDescription = try await container.visionGenerator.describe(
                            imageData: analysisData,
                            localeIdentifier: appLanguage == "system" ? Locale.current.identifier : appLanguage
                        )
                        PointVerseLog.storage.info("Attached photo understood by vision model")
                    } catch {
                        visualDescription = nil
                        let nsError = error as NSError
                        PointVerseLog.storage.error("Attached photo vision analysis failed: domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)")
                    }
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
            await container.visionGenerator.releaseResources()
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

    private func analyzePhotos() {
        guard visionAvailable, !pointImages.isEmpty else { return }
        isAnalyzingPhotos = true
        photoAnalysisKey = nil
        Task {
            await container.transcriptionService.releaseLanguageModel()
            var successCount = 0
            for item in pointImages {
                do {
                    let url = try await container.imageBlobStore.url(for: item.asset.relativePath)
                    let data = try Data(contentsOf: url)
                    guard let analysisData = Self.analysisJPEG(from: data) else { continue }
                    let description = try await container.visionGenerator.describe(
                        imageData: analysisData,
                        localeIdentifier: appLanguage == "system" ? Locale.current.identifier : appLanguage
                    )
                    let ocr = try? await container.imageTextRecognizer.recognize(data: data, language: appLanguage)
                    let context = [description, ocr].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }.joined(separator: "\n")
                    try await container.database.updateImageText(id: item.id, recognizedText: context)
                    successCount += 1
                } catch {
                    let nsError = error as NSError
                    PointVerseLog.storage.error("Photo re-analysis failed: domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)")
                }
            }
            await container.visionGenerator.releaseResources()
            if successCount > 0 {
                _ = await container.transcriptionService.deriveTitle(pointID: point.id, languageIdentifier: appLanguage)
                photoAnalysisKey = "照片理解完成，已更新点子上下文"
            } else {
                photoAnalysisKey = "照片理解失败"
            }
            isAnalyzingPhotos = false
            await reload()
        }
    }

    private func duration(_ milliseconds: Int) -> String {
        let seconds = milliseconds / 1_000
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private static func compressedJPEG(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImageFromSource(destination, source, 0, [
            kCGImageDestinationLossyCompressionQuality: 0.85
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static func analysisJPEG(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 512,
                kCGImageSourceShouldCacheImmediately: false
              ] as CFDictionary) else { return nil }
        return autoreleasepool { UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.85) }
    }

    private static func thumbnail(from data: Data, maxPixelSize: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

private struct CameraCaptureView: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: CameraCaptureView
        init(parent: CameraCaptureView) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage else {
                parent.onCancel()
                return
            }
            parent.onCapture(image)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCancel()
        }
    }
}

private struct PointManifestationView: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLanguage) private var appLanguage
    let pointID: PointID
    let sourceContext: String
    let onSaved: () -> Void
    @State private var generatedImage: UIImage?
    @State private var generatedPrompt = ""
    @State private var isGenerating = false
    @State private var diffusionStarted = false
    @State private var progress = 0.0
    @State private var errorKey: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if let generatedImage {
                    Image(uiImage: generatedImage).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                    Button(action: saveToTimeline) {
                        Label { AppText("加入想法") } icon: { Image(systemName: "checkmark.circle.fill") }
                    }.buttonStyle(.borderedProminent)
                } else if isGenerating {
                    Spacer()
                    if diffusionStarted {
                        ProgressView(value: progress)
                        Text(verbatim: "\(Int(progress * 100))%").monospacedDigit().foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                        AppText("正在整理想法并加载图片模型").foregroundStyle(.secondary)
                    }
                    Spacer()
                } else {
                    Spacer()
                    Image(systemName: "wand.and.stars").font(.system(size: 52)).foregroundStyle(.indigo)
                    AppText("把这条想法显影成图片").font(.title3.weight(.semibold))
                    AppText("将使用原音转写、照片和对话作为上下文").foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button(action: generate) { AppText("开始显影") }.buttonStyle(.borderedProminent)
                    Spacer()
                }
                if let errorKey { AppText(errorKey).foregroundStyle(.red) }
            }
            .padding()
            .navigationTitle(AppLocalization.string("显影", language: appLanguage))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { AppText("取消") } } }
        }
    }

    private func generate() {
        guard !sourceContext.isEmpty else { return }
        isGenerating = true
        diffusionStarted = false
        progress = 0
        errorKey = nil
        Task {
            do {
                let locale = appLanguage == "system" ? Locale.current.identifier : appLanguage
                generatedPrompt = try await container.promptTranslator.translateImagePromptToEnglish(
                    "Create one coherent visual interpretation of this saved idea. " + sourceContext,
                    localeIdentifier: locale
                )
                let url = try await container.imageGenerator.generate(prompt: generatedPrompt) { value in
                    Task { @MainActor in diffusionStarted = true; progress = value }
                }
                generatedImage = UIImage(contentsOfFile: url.path)
                progress = 1
            } catch PointVerseError.modelNotInstalled {
                errorKey = "请先安装语言模型和图片模型"
            } catch {
                errorKey = "显影失败"
            }
            isGenerating = false
        }
    }

    private func saveToTimeline() {
        guard let data = generatedImage?.jpegData(compressionQuality: 0.9) else { return }
        Task {
            do {
                let id = UUID()
                let stored = try await container.imageBlobStore.saveJPEG(data, assetID: id)
                try await container.database.addImage(pointID: pointID, id: id, relativePath: stored.relativePath,
                                                      sha256: stored.sha256, byteCount: stored.byteCount,
                                                      recognizedText: generatedPrompt)
                NotificationCenter.default.post(name: Notification.Name("PointVersePointImagesDidChange"),
                                                object: pointID.rawValue.uuidString)
                onSaved()
            } catch { errorKey = "显影图片保存失败" }
        }
    }
}

private struct LoadedPointImage: Identifiable {
    let asset: PointImage
    let image: UIImage
    var id: UUID { asset.id }
}

private enum DetailTimelineItem: Identifiable {
    case photo(LoadedPointImage)
    case message(ConversationMessage)

    var id: String {
        switch self {
        case .photo(let photo): "photo-" + photo.id.uuidString
        case .message(let message): "message-" + message.id.uuidString
        }
    }

    var createdAt: Date {
        switch self {
        case .photo(let photo): photo.asset.createdAt
        case .message(let message): message.createdAt
        }
    }
}

private struct PhotoCropSource: Identifiable {
    let id = UUID()
    let originalData: Data
    let preview: UIImage
}
