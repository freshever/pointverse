import PointVerseKit
import PencilKit
import PhotosUI
import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers

struct PointDetailView: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLanguage) private var appLanguage
    @StateObject private var player = AudioPlayerViewModel()
    @State private var detail: PointDetail?
    @State private var images: [LoadedPointImage] = []
    @State private var messages: [ConversationMessage] = []
    @State private var relatedPoints: [RelatedPoint] = []
    @State private var relatedLoaded = false
    @State private var editedTranscript = ""
    @State private var isEditing = false
    @State private var isSaving = false
    @State private var confirmingDelete = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var showingPhotoPicker = false
    @State private var showingCamera = false
    @State private var showingDoodle = false
    @State private var cropSource: PhotoCropSource?
    @State private var isAddingPhotos = false
    @State private var photoError = false
    @State private var isAnalyzingPhotos = false
    @State private var visionAvailable = false
    @State private var visionAvailabilityChecked = false
    @State private var photoAnalysisKey: String?
    @State private var showingManifestation = false
    let point: PointSummary

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if detail?.modality != "text" { audioCard }
                transcriptCard
                relatedPointsCard
                ForEach(images) { item in
                    VStack(alignment: .leading, spacing: 10) {
                        ZStack(alignment: .topTrailing) {
                            Image(uiImage: item.image)
                                .resizable().scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                            Button(role: .destructive) { removePhoto(item) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.65))
                            }
                            .padding(7).buttonStyle(.plain)
                        }
                        if let text = item.asset.recognizedText, !text.isEmpty {
                            Label { Text(verbatim: text).textSelection(.enabled) } icon: {
                                Image(systemName: "eye.circle")
                            }
                            .font(.subheadline).foregroundStyle(.secondary)
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
                    .padding(12)
                    .background(.background, in: RoundedRectangle(cornerRadius: 20))
                }
                if isAddingPhotos { HStack { ProgressView(); AppText("正在保存照片") } }
                if isAnalyzingPhotos { HStack { ProgressView(); AppText("正在理解照片") } }
                if photoError { AppText("照片保存失败").foregroundStyle(.red) }
                if !images.isEmpty && visionAvailabilityChecked && !visionAvailable {
                    AppText("请先安装完整的 Qwen3-VL 和视觉投影模型").foregroundStyle(.orange)
                } else if let photoAnalysisKey {
                    AppText(photoAnalysisKey).foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .onChange(of: selectedPhotos) { _, items in prepareCrop(items.first) }
        .photosPicker(isPresented: $showingPhotoPicker, selection: $selectedPhotos,
                      maxSelectionCount: 1, matching: .images)
        .sheet(item: $cropSource) { source in
            SquarePhotoCropView(image: source.preview, onCancel: {
                cropSource = nil; selectedPhotos = []
            }, onConfirm: { analysisData in
                cropSource = nil; selectedPhotos = []
                addPhoto(sourceData: source.originalData, analysisData: analysisData)
            })
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraCaptureView { image in
                showingCamera = false
                prepareCapturedPhoto(image)
            } onCancel: { showingCamera = false }
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showingDoodle) {
            DoodleCaptureView { data in
                showingDoodle = false
                guard let analysisData = Self.analysisJPEG(from: data) else {
                    photoError = true
                    return
                }
                addPhoto(sourceData: data, analysisData: analysisData)
            } onCancel: {
                showingDoodle = false
            }
        }
        .sheet(isPresented: $showingManifestation) {
            PointManifestationView(pointID: point.id, sourceContext: manifestationContext) {
                showingManifestation = false
                Task { await reload() }
            }
            .environmentObject(container)
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("PointVersePointImagesDidChange"))) { note in
            guard note.object as? String == point.id.rawValue.uuidString else { return }
            Task { await reload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: TranscriptionService.didChangeNotification)) { note in
            guard note.object as? String == point.id.rawValue.uuidString else { return }
            Task { await reload() }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingManifestation = true } label: {
                    Label { AppText("显影") } icon: { Image(systemName: "wand.and.stars") }
                }
                .disabled((detail?.effectiveTranscript?.isEmpty != false) && images.isEmpty)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showingCamera = true } label: { Label("拍照", systemImage: "camera") }
                        .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                    Button { showingPhotoPicker = true } label: { Label("从相册选择", systemImage: "photo.on.rectangle") }
                    Button { showingDoodle = true } label: { Label("涂鸦", systemImage: "pencil.tip.crop.circle") }
                    if !images.isEmpty {
                        Button(action: analyzePhotos) { Label("重新理解照片", systemImage: "eye.circle") }
                            .disabled(isAnalyzingPhotos || !visionAvailable)
                    }
                    Divider()
                    if detail?.transcriptState == "failed" {
                        Button { retryTranscription() } label: { Label("重新转写", systemImage: "arrow.clockwise") }
                    }
                    Button(role: .destructive) { confirmingDelete = true } label: { Label("删除", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .confirmationDialog("删除这条想法？", isPresented: $confirmingDelete) {
            Button("删除", role: .destructive) {
                Task { try? await container.deletePoint(point.id); dismiss() }
            }
        } message: { Text("原音、转写和照片都会被永久删除。") }
    }

    private var audioCard: some View {
        HStack(spacing: 14) {
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 44, height: 44).background(.indigo, in: Circle()).foregroundStyle(.white)
            }
            .disabled(!player.isReady)
            VStack(alignment: .leading, spacing: 3) {
                Text("原音已保存").font(.headline)
                if let milliseconds = detail?.durationMilliseconds {
                    Text(duration(milliseconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(16).background(.background, in: RoundedRectangle(cornerRadius: 20))
    }

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(detail?.modality == "text" ? "文本内容" : "系统语音转写",
                  systemImage: detail?.modality == "text" ? "text.alignleft" : "text.quote").font(.headline)
            if let detail {
                if detail.modality == "text" {
                    Text(verbatim: detail.sourceText ?? "").textSelection(.enabled)
                } else { switch detail.transcriptState {
                case "succeeded":
                    if isEditing {
                        TextEditor(text: $editedTranscript).frame(minHeight: 120)
                        Button("保存修正") { saveCorrection() }
                            .buttonStyle(.borderedProminent).disabled(isSaving || editedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else {
                        Text(verbatim: detail.effectiveTranscript ?? "没有识别到文字").textSelection(.enabled)
                        Button("修正文字") { editedTranscript = detail.effectiveTranscript ?? ""; isEditing = true }.font(.footnote)
                    }
                case "running", "queued":
                    HStack { ProgressView(); Text("正在设备端转写") }.foregroundStyle(.secondary)
                case "failed":
                    Text(detail.transcriptErrorCode == PointVerseError.onDeviceRecognitionUnavailable.rawValue
                         ? "当前设备或语言不支持设备端转写，原音仍已保存。" : "转写失败，原音仍已保存。")
                        .foregroundStyle(.secondary)
                    Button("重新转写") { retryTranscription() }
                default: Text("等待转写").foregroundStyle(.secondary)
                }
                }
            } else { ProgressView() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16).background(.background, in: RoundedRectangle(cornerRadius: 20))
    }

    private var relatedPointsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("候选关联", systemImage: "point.3.connected.trianglepath.dotted").font(.headline)
                Spacer()
                Text("E5 多语言").font(.caption2.bold()).foregroundStyle(.mint)
            }
            if !relatedLoaded {
                HStack { ProgressView(); Text("正在分析关联") }.font(.subheadline).foregroundStyle(.secondary)
            } else if relatedPoints.isEmpty {
                Text("暂时没有达到召回阈值的候选内容")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(relatedPoints) { related in
                    NavigationLink {
                        PointDetailView(point: related.point)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Circle().fill(relationColor(related.score)).frame(width: 9, height: 9).padding(.top, 6)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(related.point.title.isEmpty ? "未命名想法" : related.point.title)
                                    .font(.subheadline.bold()).foregroundStyle(.primary).lineLimit(1)
                                Text(related.content).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer(minLength: 8)
                            Text(related.score, format: .number.precision(.fractionLength(3)))
                                .font(.caption.monospacedDigit().bold())
                                .foregroundStyle(relationColor(related.score))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(relationColor(related.score).opacity(0.12), in: Capsule())
                        }
                    }
                    .buttonStyle(.plain)
                    if related.id != relatedPoints.last?.id { Divider() }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16).background(.background, in: RoundedRectangle(cornerRadius: 20))
    }

    private func relationColor(_ score: Float) -> Color {
        score >= 0.94 ? .mint : score >= 0.89 ? .cyan : .indigo
    }

    private var displayTitle: String {
        let value = detail?.title ?? point.title
        return value.isEmpty ? "语音想法" : value
    }

    private func reload() async {
        relatedLoaded = false
        async let related = container.database.relatedPoints(
            to: point.id, modelID: EmbeddingModelIdentity.multilingualE5Small,
            minimumScore: 0.85, limit: 5
        )
        guard let loaded = try? await container.database.pointDetail(id: point.id) else { return }
        detail = loaded
        messages = (try? await container.database.conversationMessages(pointID: point.id)) ?? []
        if let path = loaded.audioRelativePath,
           let url = try? await container.blobStore.url(for: path) { player.prepare(url: url) }
        let assets = (try? await container.database.images(pointID: point.id)) ?? []
        images = await withTaskGroup(of: LoadedPointImage?.self) { group in
            for asset in assets {
                group.addTask {
                    guard let url = try? await container.imageBlobStore.url(for: asset.relativePath),
                          let data = try? Data(contentsOf: url),
                          let image = Self.thumbnail(from: data, maxPixelSize: 800) else { return nil }
                    return LoadedPointImage(asset: asset, image: image)
                }
            }
            var result: [LoadedPointImage] = []
            for await item in group { if let item { result.append(item) } }
            return result.sorted { $0.asset.createdAt < $1.asset.createdAt }
        }
        relatedPoints = (try? await related) ?? []
        visionAvailable = await container.visionGenerator.isAvailable()
        visionAvailabilityChecked = true
        relatedLoaded = true
    }

    private var manifestationContext: String {
        var parts: [String] = []
        if let transcript = detail?.effectiveTranscript, !transcript.isEmpty {
            parts.append("Voice note: " + String(transcript.prefix(700)))
        }
        let photoContext = images.compactMap(\.asset.recognizedText).prefix(3).joined(separator: "\n")
        if !photoContext.isEmpty { parts.append("Photo context:\n" + String(photoContext.prefix(600))) }
        let discussion = messages.suffix(4).map {
            ($0.role == "user" ? "User: " : "Assistant: ") + String($0.text.prefix(180))
        }.joined(separator: "\n")
        if !discussion.isEmpty { parts.append("Discussion:\n" + discussion) }
        return parts.joined(separator: "\n\n")
    }

    private func prepareCrop(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let preview = Self.thumbnail(from: data, maxPixelSize: 2_048) else {
                photoError = true; selectedPhotos = []; return
            }
            cropSource = PhotoCropSource(originalData: data, preview: preview)
        }
    }

    private func prepareCapturedPhoto(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.95),
              let preview = Self.thumbnail(from: data, maxPixelSize: 2_048) else { photoError = true; return }
        cropSource = PhotoCropSource(originalData: data, preview: preview)
    }

    private func addPhoto(sourceData source: Data, analysisData: Data) {
        isAddingPhotos = true; photoError = false
        Task {
            do {
                await container.promptTranslator.releaseResources()
                guard let data = Self.compressedJPEG(from: source) else { throw PointVerseError.invalidModelOutput }
                let id = UUID()
                let stored = try await container.imageBlobStore.saveJPEG(data, assetID: id)
                let ocr = try? await container.imageTextRecognizer.recognize(data: data, language: appLanguage)
                let visual = try? await container.visionGenerator.describe(
                    imageData: analysisData,
                    localeIdentifier: appLanguage == "system" ? Locale.current.identifier : appLanguage
                )
                let context = [visual, ocr].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }.joined(separator: "\n")
                do {
                    try await container.database.addImage(pointID: point.id, id: id, relativePath: stored.relativePath,
                                                          sha256: stored.sha256, byteCount: stored.byteCount,
                                                          recognizedText: context.isEmpty ? nil : context)
                } catch {
                    try? await container.imageBlobStore.delete(relativePath: stored.relativePath); throw error
                }
                if visual == nil { photoAnalysisKey = "照片已保存，图片理解暂时不可用" }
            } catch { photoError = true }
            await container.visionGenerator.releaseResources()
            isAddingPhotos = false
            container.refreshEmbeddings()
            await reload()
        }
    }

    private func removePhoto(_ item: LoadedPointImage) {
        Task {
            guard let path = try? await container.database.removeImage(id: item.id) else { return }
            try? await container.imageBlobStore.delete(relativePath: path)
            container.refreshEmbeddings()
            await reload()
        }
    }

    private func analyzePhotos() {
        guard visionAvailable, !images.isEmpty else { return }
        isAnalyzingPhotos = true; photoAnalysisKey = nil
        Task {
            await container.promptTranslator.releaseResources()
            var successCount = 0
            for item in images {
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
                    let value = error as NSError
                    PointVerseLog.storage.error("Photo analysis failed: domain=\(value.domain, privacy: .public) code=\(value.code, privacy: .public)")
                }
            }
            await container.visionGenerator.releaseResources()
            photoAnalysisKey = successCount > 0 ? "照片理解完成，已更新点子上下文" : "照片理解失败"
            isAnalyzingPhotos = false
            container.refreshEmbeddings()
            await reload()
        }
    }

    nonisolated private static func compressedJPEG(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImageFromSource(destination, source, 0,
                                             [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    nonisolated private static func analysisJPEG(from data: Data) -> Data? {
        guard let image = thumbnail(from: data, maxPixelSize: 512) else { return nil }
        return autoreleasepool { image.jpegData(compressionQuality: 0.85) }
    }

    nonisolated private static func thumbnail(from data: Data, maxPixelSize: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceShouldCacheImmediately: false
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private func saveCorrection() {
        isSaving = true
        Task {
            try? await container.database.saveUserTranscript(pointID: point.id, userText: editedTranscript)
            container.refreshEmbeddings()
            isSaving = false; isEditing = false; await reload()
        }
    }

    private func retryTranscription() {
        Task {
            await container.transcriptionService.transcribe(pointID: point.id)
            container.refreshEmbeddings()
            await reload()
        }
    }

    private func duration(_ milliseconds: Int) -> String {
        let seconds = milliseconds / 1_000
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct LoadedPointImage: Identifiable {
    var id: UUID { asset.id }
    let asset: PointImage
    let image: UIImage
}

private struct PhotoCropSource: Identifiable {
    let id = UUID()
    let originalData: Data
    let preview: UIImage
}

private struct DoodleCaptureView: View {
    @Environment(\.appLanguage) private var appLanguage
    @State private var drawing = PKDrawing()
    @State private var canvasSize: CGSize = .zero
    let onSave: (Data) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                DoodleCanvas(drawing: $drawing)
                    .background(Color.white)
                    .onAppear { canvasSize = proxy.size }
                    .onChange(of: proxy.size) { _, value in canvasSize = value }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(AppLocalization.string("涂鸦", language: appLanguage))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: onCancel) { AppText("取消") }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { drawing = PKDrawing() } label: { AppText("清空") }
                        .disabled(drawing.strokes.isEmpty)
                    Button {
                        if let data = renderedJPEG() { onSave(data) }
                    } label: { AppText("完成") }
                    .fontWeight(.semibold)
                    .disabled(drawing.strokes.isEmpty || canvasSize.width < 1 || canvasSize.height < 1)
                }
            }
        }
    }

    private func renderedJPEG() -> Data? {
        let sourceBounds = CGRect(origin: .zero, size: canvasSize)
        let targetWidth: CGFloat = 1_024
        let targetSize = CGSize(width: targetWidth, height: targetWidth * canvasSize.height / canvasSize.width)
        let sketch = drawing.image(from: sourceBounds, scale: targetWidth / canvasSize.width)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: targetSize, format: format).jpegData(withCompressionQuality: 0.9) { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: targetSize))
            sketch.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}

private struct DoodleCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing

    func makeCoordinator() -> Coordinator { Coordinator(drawing: $drawing) }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.delegate = context.coordinator
        canvas.drawing = drawing
        canvas.drawingPolicy = .anyInput
        canvas.backgroundColor = .white
        canvas.isOpaque = true
        canvas.tool = PKInkingTool(.pen, color: .black, width: 5)
        DispatchQueue.main.async {
            context.coordinator.toolPicker.setVisible(true, forFirstResponder: canvas)
            context.coordinator.toolPicker.addObserver(canvas)
            canvas.becomeFirstResponder()
        }
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        if canvas.drawing != drawing { canvas.drawing = drawing }
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        @Binding var drawing: PKDrawing
        let toolPicker = PKToolPicker()

        init(drawing: Binding<PKDrawing>) { _drawing = drawing }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) { drawing = canvasView.drawing }
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
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage else { parent.onCancel(); return }
            parent.onCapture(image)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.onCancel() }
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
                    }
                    .buttonStyle(.borderedProminent)
                } else if isGenerating {
                    Spacer()
                    if diffusionStarted {
                        ProgressView(value: progress)
                        Text(verbatim: "\(Int(progress * 100))%")
                            .monospacedDigit().foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                        AppText("正在整理想法并加载图片模型").foregroundStyle(.secondary)
                    }
                    Spacer()
                } else {
                    Spacer()
                    Image(systemName: "wand.and.stars").font(.system(size: 52)).foregroundStyle(.indigo)
                    AppText("把这条想法显影成图片").font(.title3.weight(.semibold))
                    AppText("将使用原音转写、照片和对话作为上下文")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button(action: generate) { AppText("开始显影") }.buttonStyle(.borderedProminent)
                    Spacer()
                }
                if let errorKey { AppText(errorKey).foregroundStyle(.red) }
            }
            .padding()
            .navigationTitle(AppLocalization.string("显影", language: appLanguage))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { AppText("取消") }
                }
            }
        }
    }

    private func generate() {
        guard !sourceContext.isEmpty else { return }
        isGenerating = true; diffusionStarted = false; progress = 0; errorKey = nil
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
                container.refreshEmbeddings()
                onSaved()
            } catch { errorKey = "显影图片保存失败" }
        }
    }
}
