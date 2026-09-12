import PointVerseKit
import Photos
import PhotosUI
import SwiftUI
import UIKit

struct ImageGenerationView: View {
    private enum InputField: Hashable { case prompt, recognizedText }
    @EnvironmentObject private var container: AppContainer
    @Environment(\.appLanguage) private var appLanguage
    @State private var prompt = ""
    @State private var image: UIImage?
    @State private var translatedPrompt = ""
    @State private var isGenerating = false
    @State private var generationProgress = 0.0
    @State private var diffusionStarted = false
    @State private var isTranslatingPrompt = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var sourceImage: UIImage?
    @State private var recognizedText = ""
    @State private var isRecognizing = false
    @State private var noticeKey: String?
    @State private var errorKey: String?
    @FocusState private var focusedField: InputField?

    var body: some View {
        let chooseImageTitle = AppLocalization.string("选择图片", language: appLanguage)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                TextField(AppLocalization.string("描述想生成的图片", language: appLanguage), text: $prompt, axis: .vertical)
                    .lineLimit(3...6).textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .prompt)
                Button(action: generate) {
                    if isGenerating { HStack { ProgressView(); AppText("正在本地生成图片") } }
                    else { Label { AppText("生成图片") } icon: { Image(systemName: "sparkles") } }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isGenerating || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if isGenerating {
                    VStack(alignment: .leading, spacing: 5) {
                        if isTranslatingPrompt {
                            ProgressView()
                            AppText("正在生成英文提示词").font(.caption).foregroundStyle(.secondary)
                        } else if diffusionStarted {
                            ProgressView(value: generationProgress, total: 1)
                            Text(verbatim: "\(Int(generationProgress * 100))%")
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        } else {
                            ProgressView()
                            AppText("正在加载图片模型").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if !translatedPrompt.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        AppText("实际生图提示词").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(verbatim: translatedPrompt).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                if let image {
                    Image(uiImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 16))
                    Button(action: saveGeneratedImage) {
                        Label { AppText("保存到相册") } icon: { Image(systemName: "square.and.arrow.down") }
                    }
                    .buttonStyle(.bordered)
                }
                if let errorKey { AppText(errorKey).foregroundStyle(.red).font(.footnote) }
                AppText("图片完全在设备端生成，首次运行可能需要较长时间。")
                    .font(.footnote).foregroundStyle(.secondary)

                Divider().padding(.vertical, 4)
                AppText("图片提取文字").font(.headline)
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Label(chooseImageTitle, systemImage: "photo.on.rectangle")
                }
                .buttonStyle(.borderedProminent)
                if let sourceImage {
                    Image(uiImage: sourceImage).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 16))
                }
                if isRecognizing { HStack { ProgressView(); AppText("正在识别图片文字") } }
                if !recognizedText.isEmpty {
                    TextEditor(text: $recognizedText)
                        .frame(minHeight: 140)
                        .focused($focusedField, equals: .recognizedText)
                        .padding(6)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.secondary.opacity(0.3)))
                    ShareLink(item: recognizedText) {
                        Label { AppText("分享文字") } icon: { Image(systemName: "square.and.arrow.up") }
                    }
                }
                AppText("文字识别完全在设备端完成，不会上传图片。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .onTapGesture { focusedField = nil }
        .navigationTitle(AppLocalization.string("图片生成", language: appLanguage))
        .onChange(of: prompt) { _, _ in translatedPrompt = "" }
        .onChange(of: selectedPhoto) { _, item in loadAndRecognize(item) }
        .alert(AppLocalization.string(noticeKey ?? "好", language: appLanguage), isPresented: Binding(
            get: { noticeKey != nil },
            set: { if !$0 { noticeKey = nil } }
        )) { Button(AppLocalization.string("好", language: appLanguage)) { noticeKey = nil } }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button { focusedField = nil } label: { AppText("完成") }
            }
        }
    }

    private func generate() {
        let value = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        isGenerating = true
        generationProgress = 0
        diffusionStarted = false
        isTranslatingPrompt = true
        errorKey = nil
        Task {
            do {
                let localeIdentifier = appLanguage == "system" ? Locale.current.identifier : appLanguage
                let generationPrompt: String
                do {
                    generationPrompt = try await container.promptTranslator.translateImagePromptToEnglish(
                        value,
                        localeIdentifier: localeIdentifier
                    )
                    translatedPrompt = generationPrompt == value ? "" : generationPrompt
                } catch {
                    generationPrompt = value
                    translatedPrompt = ""
                    PointVerseLog.storage.notice("Image prompt translation unavailable; using original prompt")
                }
                isTranslatingPrompt = false
                let url = try await container.imageGenerator.generate(prompt: generationPrompt) { progress in
                    Task { @MainActor in
                        diffusionStarted = true
                        generationProgress = progress
                    }
                }
                image = UIImage(contentsOfFile: url.path)
                generationProgress = 1
            } catch PointVerseError.modelNotInstalled { errorKey = "请先在模型页下载图片模型" }
            catch { errorKey = "图片生成失败" }
            isTranslatingPrompt = false
            isGenerating = false
        }
    }

    private func saveGeneratedImage() {
        guard let image, let pngData = image.pngData() else {
            noticeKey = "保存图片失败"
            return
        }
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                noticeKey = "请允许访问相册以保存图片"
                return
            }
            do {
                try await PhotoLibrarySaver.savePNGData(pngData)
                noticeKey = "图片已保存到相册"
            } catch {
                noticeKey = "保存图片失败"
            }
        }
    }

    private func loadAndRecognize(_ item: PhotosPickerItem?) {
        guard let item else { return }
        isRecognizing = true
        recognizedText = ""
        errorKey = nil
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self), let loaded = UIImage(data: data) else {
                    throw PointVerseError.invalidModelOutput
                }
                sourceImage = loaded
                let text = try await container.imageTextRecognizer.recognize(data: data, language: appLanguage)
                recognizedText = text
                if text.isEmpty { noticeKey = "没有识别到图片文字" }
            } catch {
                errorKey = "图片文字识别失败"
            }
            isRecognizing = false
        }
    }
}
