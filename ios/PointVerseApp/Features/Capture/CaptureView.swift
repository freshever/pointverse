@preconcurrency import AVFoundation
import SwiftUI
import UIKit
import PointVerseKit

struct CaptureView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var state: CaptureState = .idle
    @State private var startedAt: Date?
    @State private var elapsed = 0
    @State private var failureKey = "录音启动失败"
    @State private var recordingStartTask: Task<Void, Never>?
    @State private var activeLocaleIdentifier: String?
    @StateObject private var camera = CameraFrameSampler()
    @AppStorage("captureCameraEnabled") private var cameraEnabled = true
    @State private var frameReview: CapturedFrameReview?
    @State private var completedPoint: PointSummary?
    @AppStorage("captureLanguage") private var captureLanguage = ""
    @AppStorage("captureInputMode") private var inputMode = "voice"
    @State private var textInput = ""
    @State private var isSavingText = false
    @Environment(\.appLanguage) private var appLanguage

    var body: some View {
        VStack(spacing: 0) {
            Picker("输入方式", selection: $inputMode) {
                Label("语音", systemImage: "waveform").tag("voice")
                Label("文本", systemImage: "keyboard").tag("text")
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20).padding(.vertical, 10)

            if inputMode == "text" { textCaptureContent } else { voiceCaptureContent }
        }
        .navigationTitle(AppLocalization.string("点界", language: appLanguage))
        .navigationDestination(isPresented: Binding(
            get: { completedPoint != nil },
            set: { if !$0 { completedPoint = nil } }
        )) {
            if let completedPoint { PointDetailView(point: completedPoint) }
        }
        .onAppear {
            if ProcessInfo.processInfo.isiOSAppOnMac, inputMode == "voice" {
                inputMode = "text"
                cameraEnabled = false
            }
        }
    }

    private var voiceCaptureContent: some View {
        ZStack {
            if cameraEnabled {
                CameraPreview(session: camera.session)
                    .ignoresSafeArea()
                LinearGradient(
                    colors: [.black.opacity(0.5), .black.opacity(0.12), .black.opacity(0.48)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            } else {
                Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
            }

            VStack(spacing: 28) {
            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                VStack(spacing: 3) {
                    Text(timeline.date.formatted(date: .long, time: .omitted))
                        .font(.headline)
                    Text(timeline.date.formatted(date: .omitted, time: .shortened))
                        .font(.title3.monospacedDigit().weight(.medium))
                }
                .foregroundStyle(.secondary)
                .environment(\.locale, captureDisplayLocale)
                .accessibilityElement(children: .combine)
            }

            Spacer()
            AppText(state.title)
                .font(.title2.weight(.semibold))
            if state == .recording {
                Text(String(format: "%02d:%02d", elapsed / 60, elapsed % 60))
                    .foregroundStyle(.secondary)
            } else {
                AppText(state == .failed ? failureKey : state.detail)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Picker(selection: $captureLanguage) {
                AppText("自动").tag("")
                AppText("简体中文").tag("zh-CN")
                AppText("繁体中文").tag("zh-TW")
                AppText("英文").tag("en-US")
                AppText("日文").tag("ja-JP")
            } label: {
                AppText("录音语言")
            }
            .pickerStyle(.menu)
            .disabled(state == .recording || state == .saving)

            Toggle(isOn: $cameraEnabled) {
                Label { AppText("同时拍摄") } icon: { Image(systemName: "camera") }
            }
            .tint(.indigo)
            .disabled(state == .recording || state == .saving)
            .onChange(of: cameraEnabled) { _, enabled in
                if enabled {
                    startCameraPreview()
                } else {
                    camera.stopPreview()
                    camera.cancelCollecting()
                }
            }

            ZStack {
                Circle()
                    .fill(state == .recording ? Color.red : Color.indigo)
                Image(systemName: state == .recording ? "stop.fill" : "viewfinder")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 112, height: 112)
            .scaleEffect(state == .recording ? 1.08 : 1)
            .animation(.easeOut(duration: 0.12), value: state)
            .contentShape(Circle())
            .onTapGesture {
                if state == .recording { finishRecording() }
                else { beginRecording() }
            }
            .accessibilityLabel(AppLocalization.string(state == .recording ? "完成录音" : "开始录音", language: appLanguage))
            .accessibilityHint(AppLocalization.string(state == .recording ? "轻点结束录音" : "轻点开始录音", language: appLanguage))
            .disabled(state == .saving)

            AppText(state == .recording ? "再次轻点结束" : "轻点开始")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(state == .recording ? .red : .secondary)

            if state == .recording {
                Button(role: .cancel) {
                    Task {
                        camera.cancelCollecting()
                        await container.captureUseCase.cancel()
                        activeLocaleIdentifier = nil
                        state = .idle
                    }
                } label: { AppText("取消") }
            }
            if state == .permissionDenied {
                Button {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                } label: {
                    AppText("前往设置")
                }
            }
            Spacer()
            }
            .padding(24)
        }
        .preferredColorScheme(cameraEnabled ? .dark : nil)
        .onAppear {
            if cameraEnabled { startCameraPreview() }
        }
        .onDisappear {
            camera.stopPreview()
        }
        .task(id: startedAt) {
            guard let startedAt else { return }
            while !Task.isCancelled {
                elapsed = Int(Date().timeIntervalSince(startedAt))
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .sheet(item: $frameReview) { review in
            FrameReviewView(review: review) { selected in
                frameReview = nil
                openDetail(for: review.pointID)
                finishCaptureWithFrames(pointID: review.pointID, frames: selected, localeIdentifier: review.localeIdentifier)
            } onSkip: {
                frameReview = nil
                openDetail(for: review.pointID)
                Task {
                    await container.transcriptionService.transcribe(pointID: review.pointID)
                    container.refreshEmbeddings()
                }
            }
        }
    }

    private var textCaptureContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("此刻，想到什么？").font(.title2.bold())
                Text("文本会直接保存为一颗星，不需要模型处理。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            TextEditor(text: $textInput)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(12)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                .frame(minHeight: 220)
                .overlay(alignment: .topLeading) {
                    if textInput.isEmpty {
                        Text("写下一句话、一个问题，或还没成形的念头……")
                            .foregroundStyle(.tertiary).padding(.horizontal, 18).padding(.vertical, 20)
                            .allowsHitTesting(false)
                    }
                }
            Button {
                saveTextPoint()
            } label: {
                if isSavingText { ProgressView().frame(maxWidth: .infinity) }
                else { Label("保存为 Point", systemImage: "sparkles").frame(maxWidth: .infinity) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isSavingText || textInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Spacer()
        }
        .padding(20)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func saveTextPoint() {
        let text = textInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isSavingText = true
        Task {
            do {
                let id = try await container.database.commitTextPoint(text: text, createdAt: Date())
                container.refreshEmbeddings()
                let title = text.count > 20 ? String(text.prefix(20)) + "…" : text
                textInput = ""
                completedPoint = PointSummary(id: id, title: title, createdAt: Date(), transcriptState: "text")
            } catch {
                failureKey = "无法保存文本"
            }
            isSavingText = false
        }
    }

    private func beginRecording() {
        guard state == .idle || state == .saved || state == .failed else { return }
        let localeIdentifier = resolvedCaptureLocaleIdentifier
        activeLocaleIdentifier = localeIdentifier
        PointVerseLog.capture.info("Recording language locked: \(localeIdentifier, privacy: .public)")
        recordingStartTask = Task {
            do {
                elapsed = 0
                if cameraEnabled { camera.beginCollecting() }
                try await container.captureUseCase.start()
                startedAt = Date()
                state = .recording
            } catch PointVerseError.microphonePermissionDenied {
                camera.cancelCollecting()
                startedAt = nil
                activeLocaleIdentifier = nil
                state = .permissionDenied
            } catch let error as PointVerseError {
                camera.cancelCollecting()
                startedAt = nil
                activeLocaleIdentifier = nil
                failureKey = switch error {
                case .audioSessionUnavailable: "无法启动录音会话"
                case .insufficientDiskSpace: "设备可用空间不足"
                case .audioCommitFailed: "无法保存录音文件"
                case .databaseCommitFailed: "无法保存录音资料"
                default: "录音启动失败"
                }
                state = .failed
            } catch {
                camera.cancelCollecting()
                startedAt = nil
                activeLocaleIdentifier = nil
                failureKey = "录音启动失败"
                state = .failed
            }
        }
    }

    private func finishRecording() {
        guard state == .recording else { return }
        state = .saving
        Task {
            do {
                let localeIdentifier = activeLocaleIdentifier ?? resolvedCaptureLocaleIdentifier
                let pointID = try await container.captureUseCase.finish(localeIdentifier: localeIdentifier)
                let frames = cameraEnabled ? camera.endCollecting(maximumCount: 5) : []
                if cameraEnabled {
                    camera.stopPreview()
                }
                startedAt = nil
                activeLocaleIdentifier = nil
                state = .saved
                if frames.isEmpty {
                    openDetail(for: pointID)
                    Task {
                        await container.transcriptionService.transcribe(pointID: pointID)
                        container.refreshEmbeddings()
                    }
                } else {
                    frameReview = CapturedFrameReview(pointID: pointID, localeIdentifier: localeIdentifier,
                                                      frames: frames.map { CapturedFrame(data: $0) })
                }
            } catch let error as PointVerseError {
                startedAt = nil
                activeLocaleIdentifier = nil
                failureKey = switch error {
                case .insufficientDiskSpace: "设备可用空间不足"
                case .audioCommitFailed: "无法保存录音文件"
                case .databaseCommitFailed: "无法保存录音资料"
                default: "录音启动失败"
                }
                state = .failed
            } catch {
                startedAt = nil
                activeLocaleIdentifier = nil
                failureKey = "录音启动失败"
                state = .failed
            }
        }
    }

    private func openDetail(for pointID: PointID) {
        completedPoint = PointSummary(
            id: pointID,
            title: "",
            createdAt: Date(),
            transcriptState: "queued"
        )
    }

    private func startCameraPreview() {
        Task {
            if !(await camera.startPreview()) { cameraEnabled = false }
        }
    }

    private func finishCaptureWithFrames(pointID: PointID, frames: [CapturedFrame], localeIdentifier: String) {
        Task {
            var assets: [(UUID, Data)] = []
            for frame in frames {
                let id = UUID()
                guard let stored = try? await container.imageBlobStore.saveJPEG(frame.data, assetID: id) else { continue }
                try? await container.database.addImage(pointID: pointID, id: id, relativePath: stored.relativePath,
                                                       sha256: stored.sha256, byteCount: stored.byteCount, recognizedText: nil)
                assets.append((id, frame.data))
            }
            notifyImagesChanged(pointID)
            await container.transcriptionService.transcribe(pointID: pointID)
            container.refreshEmbeddings()
            for (id, data) in assets {
                do {
                    let text = try await container.imageTextRecognizer.recognize(
                        data: data,
                        language: localeIdentifier
                    )
                    try await container.database.updateImageText(id: id, recognizedText: text.isEmpty ? nil : text)
                    container.refreshEmbeddings()
                    notifyImagesChanged(pointID)
                    PointVerseLog.storage.info("Captured frame OCR completed")
                } catch {
                    let nsError = error as NSError
                    PointVerseLog.storage.error("Automatic captured-frame analysis failed: domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)")
                }
            }
        }
    }

    private func notifyImagesChanged(_ pointID: PointID) {
        NotificationCenter.default.post(
            name: Notification.Name("PointVersePointImagesDidChange"),
            object: pointID.rawValue.uuidString
        )
    }

    private var resolvedCaptureLocaleIdentifier: String {
        if !captureLanguage.isEmpty { return captureLanguage }
        if appLanguage != "system", !appLanguage.isEmpty {
            switch appLanguage {
            case "zh-Hans": return "zh-CN"
            case "zh-Hant": return "zh-TW"
            case "ja": return "ja-JP"
            case "en": return "en-US"
            default: break
            }
        }
        return Locale.current.identifier
    }

    private var captureDisplayLocale: Locale {
        guard appLanguage != "system", !appLanguage.isEmpty else { return .current }
        return Locale(identifier: appLanguage)
    }
}

private struct CapturedFrame: Identifiable {
    let id = UUID()
    let data: Data
    var image: UIImage? { UIImage(data: data) }
}

private struct CapturedFrameReview: Identifiable {
    let id = UUID()
    let pointID: PointID
    let localeIdentifier: String
    let frames: [CapturedFrame]
}

private struct FrameReviewView: View {
    @Environment(\.appLanguage) private var appLanguage
    let review: CapturedFrameReview
    let onConfirm: ([CapturedFrame]) -> Void
    let onSkip: () -> Void
    @State private var selected: Set<UUID>

    init(review: CapturedFrameReview, onConfirm: @escaping ([CapturedFrame]) -> Void, onSkip: @escaping () -> Void) {
        self.review = review
        self.onConfirm = onConfirm
        self.onSkip = onSkip
        _selected = State(initialValue: Set(review.frames.map(\.id)))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(review.frames) { frame in
                        if let image = frame.image {
                            Image(uiImage: image).resizable().scaledToFill()
                                .frame(height: 190).clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                                .overlay(alignment: .topTrailing) {
                                    Image(systemName: selected.contains(frame.id) ? "checkmark.circle.fill" : "circle")
                                        .font(.title2).foregroundStyle(selected.contains(frame.id) ? .blue : .white)
                                        .padding(8)
                                }
                                .opacity(selected.contains(frame.id) ? 1 : 0.45)
                                .onTapGesture {
                                    if selected.contains(frame.id) { selected.remove(frame.id) } else { selected.insert(frame.id) }
                                }
                        }
                    }
                }.padding()
            }
            .navigationTitle(AppLocalization.string("选择有价值的画面", language: appLanguage))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(action: onSkip) { AppText("不保留照片") } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { onConfirm(review.frames.filter { selected.contains($0.id) }) } label: { AppText("保留所选") }
                }
            }
        }
        .interactiveDismissDisabled()
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewView { let view = PreviewView(); view.layerView.session = session; return view }
    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var layerView: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        override init(frame: CGRect) { super.init(frame: frame); layerView.videoGravity = .resizeAspectFill }
        required init?(coder: NSCoder) { fatalError() }
    }
}

private final class CameraFrameSampler: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "pointverse.camera.session")
    private let outputQueue = DispatchQueue(label: "pointverse.camera.frames")
    private let lock = NSLock()
    private var configured = false
    private var collecting = false
    private var lastFrameTime: CFTimeInterval = 0
    private var frames: [Data] = []
    private let context = CIContext(options: [.cacheIntermediates: false])

    func startPreview() async -> Bool {
        let granted: Bool
        if AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
            granted = true
        } else {
            granted = await AVCaptureDevice.requestAccess(for: .video)
        }
        guard granted else { return false }
        return await withCheckedContinuation { continuation in
            sessionQueue.async {
                do {
                    if !self.configured { try self.configure() }
                    if !self.session.isRunning { self.session.startRunning() }
                    continuation.resume(returning: true)
                } catch { continuation.resume(returning: false) }
            }
        }
    }

    func stopPreview() { sessionQueue.async { if self.session.isRunning { self.session.stopRunning() } } }
    func beginCollecting() { lock.withLock { frames.removeAll(keepingCapacity: true); collecting = true; lastFrameTime = 0 } }
    func cancelCollecting() { lock.withLock { collecting = false; frames.removeAll() } }

    func endCollecting(maximumCount: Int) -> [Data] {
        lock.withLock {
            collecting = false
            guard frames.count > maximumCount else { return frames }
            return (0..<maximumCount).map { frames[$0 * (frames.count - 1) / max(1, maximumCount - 1)] }
        }
    }

    private func configure() throws {
        session.beginConfiguration(); defer { session.commitConfiguration() }
        session.sessionPreset = .hd1280x720
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { throw PointVerseError.invalidModelOutput }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw PointVerseError.invalidModelOutput }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: outputQueue)
        guard session.canAddOutput(output) else { throw PointVerseError.invalidModelOutput }
        session.addOutput(output)
        configured = true
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        let shouldCapture = lock.withLock { () -> Bool in
            guard collecting, frames.count < 12, now - lastFrameTime >= 1.2 else { return false }
            lastFrameTime = now
            return true
        }
        guard shouldCapture, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        autoreleasepool {
            let source = CIImage(cvPixelBuffer: buffer).oriented(.right)
            let scale = min(1, 512 / max(source.extent.width, source.extent.height))
            let resized = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let cgImage = context.createCGImage(resized, from: resized.extent),
                  let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.85) else { return }
            lock.withLock { if collecting { frames.append(data) } }
        }
    }
}

private enum CaptureState: Equatable {
    case idle, recording, saving, saved, failed, permissionDenied

    var title: String {
        switch self {
        case .idle: "留下此刻的想法"
        case .recording: "正在录音"
        case .saving: "正在可靠保存"
        case .saved: "原音已保存"
        case .failed: "保存没有完成"
        case .permissionDenied: "需要麦克风权限"
        }
    }

    var detail: String {
        switch self {
        case .idle: "轻点开始，再次轻点结束"
        case .recording: "再次轻点即可结束"
        case .saving: "正在写入原音和本地资料库…"
        case .saved: "现在可以退出 App，原音仍会保留"
        case .failed: "录音启动失败"
        case .permissionDenied: "请在系统设置中允许点界访问麦克风"
        }
    }
}
