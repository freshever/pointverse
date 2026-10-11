import PointVerseKit
import QwenAdapter
import SwiftUI
import UniformTypeIdentifiers

struct ModelSettingsView: View {
    @AppStorage("appLanguage") private var appLanguage = "system"
    @AppStorage(ModelSelection.speechDefaultsKey) private var selectedSpeechModelID = ModelManifest.whisperBaseQ5.id
    @AppStorage(ModelSelection.languageDefaultsKey) private var selectedLanguageModelID = ModelManifest.qwen3_0_6BQ8.id
    @AppStorage(ModelSelection.imageDefaultsKey) private var selectedImageModelID = ModelManifest.stableDiffusion21Base6Bit.id
    @EnvironmentObject private var container: AppContainer
    @State private var externalModels = ExternalLanguageModelStore.load()
    @State private var showingNetworkModelEditor = false
    @State private var showingGGUFImporter = false
    @State private var isImportingGGUF = false
    @State private var externalModelError: String?
    @State private var pendingNetworkModel: ExternalLanguageModel?
    @State private var showingNetworkPrivacyConfirmation = false
    @State private var testingModelID: UUID?
    @State private var connectionResult: String?

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
                Picker(selection: Binding(get: { selectedLanguageModelID }, set: selectLanguageModel)) {
                    AppText("关闭本地整理").tag(ModelSelection.disabledLanguageModelID)
                    ForEach(ModelSelection.languageModels, id: \.id) { manifest in
                        Text(verbatim: languageName(manifest)).tag(manifest.id)
                    }
                    Text(verbatim: "Edge0 8B A1B · Experimental").tag(ModelSelection.edge0LanguageModelID)
                    ForEach(externalModels) { model in Text(verbatim: model.name).tag(model.selectionID) }
                } label: { AppText("当前模型") }

                ForEach(container.languageModelManagers, id: \.manifest.id) { manager in
                    ModelRow(manager: manager, name: languageName(manager.manifest), metadata: metadata(manager.manifest), explanation: languageExplanation(manager.manifest), isSelected: selectedLanguageModelID == manager.manifest.id, onSelect: {
                        selectedLanguageModelID = manager.manifest.id
                    }, onInstalled: regenerateTitles)
                }

                Edge0ModelRow(
                    manager: container.edge0ModelManager,
                    isSelected: selectedLanguageModelID == ModelSelection.edge0LanguageModelID,
                    onSelect: { selectedLanguageModelID = ModelSelection.edge0LanguageModelID }
                )
            } header: { AppText("本地整理") }

            Section {
                Button { showingNetworkModelEditor = true } label: {
                    Label("添加网络模型", systemImage: "network")
                }
                Button { showingGGUFImporter = true } label: {
                    Label("导入本地 GGUF", systemImage: "square.and.arrow.down")
                }.disabled(isImportingGGUF)
                if isImportingGGUF { HStack { ProgressView(); Text("正在复制本地模型…") } }
                ForEach(externalModels) { model in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: model.name)
                            Text(model.kind == .openAICompatible
                                 ? "\(model.provider?.displayName ?? "OpenAI-compatible") · \(model.remoteModel ?? "")"
                                 : "本地 GGUF")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selectedLanguageModelID == model.selectionID {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button("使用") { selectLanguageModel(model.selectionID) }.buttonStyle(.borderless)
                        }
                        if model.kind == .openAICompatible {
                            Button {
                                testConnection(model)
                            } label: {
                                if testingModelID == model.id { ProgressView().controlSize(.small) }
                                else { Image(systemName: "bolt.horizontal.circle") }
                            }
                            .disabled(testingModelID != nil)
                            .buttonStyle(.borderless)
                        }
                        Button(role: .destructive) { removeExternalModel(model) } label: {
                            Image(systemName: "trash")
                        }.buttonStyle(.borderless)
                    }
                }
                if let connectionResult { Text(verbatim: connectionResult).font(.footnote).foregroundStyle(.secondary) }
                if let externalModelError { Text(verbatim: externalModelError).font(.footnote).foregroundStyle(.red) }
            } header: { AppText("外部语言模型") }
              footer: { Text("网络模型的内容会发送到你配置的服务；API Key 仅保存在本机 Keychain。本地 GGUF 会复制到点界的模型目录。") }

            Section {
                ForEach(container.imageModelManagers, id: \.manifest.id) { manager in
                    ModelRow(
                        manager: manager,
                        name: "Stable Diffusion 2.1 Base · Core ML 6-bit",
                        metadata: metadata(manager.manifest),
                        explanation: "在设备端生成 512×512 图片；首次解压和加载需要较长时间。",
                        isSelected: selectedImageModelID == manager.manifest.id,
                        onSelect: { selectedImageModelID = manager.manifest.id }
                    )
                }
            } header: { AppText("图片生成") }

            Section {
                ForEach(container.visionModelManagers, id: \.manifest.id) { manager in
                    ModelRow(
                        manager: manager,
                        name: manager.manifest.id == ModelManifest.qwen3VL2BQ8.id
                            ? "Qwen3-VL 2B Q8_0" : "Qwen3-VL Vision Projector Q8_0",
                        metadata: metadata(manager.manifest),
                        explanation: manager.manifest.id == ModelManifest.qwen3VL2BQ8.id
                            ? "理解照片内容并用于标题和对话。需要同时安装视觉投影文件。"
                            : "把照片转换为视觉模型可以理解的内容，是 Qwen3-VL 的必要组件。",
                        isSelected: false,
                        onSelect: {},
                        canSelect: false
                    )
                }
            } header: { AppText("图片理解") }

            Section {
                ForEach(container.embeddingModelManagers, id: \.manifest.id) { manager in
                    ModelRow(
                        manager: manager,
                        name: "Multilingual E5 Small · Hark INT8",
                        metadata: metadata(manager.manifest),
                        explanation: "把转写文字转换成多语言语义坐标，用于星球上的内容聚类。首次安装后会在设备上编译一次。",
                        isSelected: true,
                        onSelect: {},
                        onInstalled: { Task { await container.prepareEmbeddingService() } },
                        onRemoved: { container.removeEmbeddingArtifacts() },
                        canSelect: false
                    )
                }
            } header: { AppText("语义分类") }

            Section {
                ForEach(container.audioUnderstandingModelManagers, id: \.manifest.id) { manager in
                    ModelRow(
                        manager: manager,
                        name: "CLAP Music · Core ML INT8",
                        metadata: metadata(manager.manifest),
                        explanation: "把音乐和现场声音转换为 512 维语义向量，用于声音标签、相似声音和语义星球定位。",
                        isSelected: true,
                        onSelect: {},
                        canSelect: false
                    )
                }
            } header: { AppText("音乐与现场声音") }
        }
        .navigationTitle(AppLocalization.string("本地模型", language: appLanguage))
        .onChange(of: selectedLanguageModelID) { _, _ in regenerateTitles() }
        .onChange(of: appLanguage) { _, _ in regenerateTitles() }
        .sheet(isPresented: $showingNetworkModelEditor) {
            NetworkModelEditor { model, key in
                externalModels.append(model)
                ExternalLanguageModelStore.save(externalModels)
                try? ExternalModelAPIKeyStore.save(key, modelID: model.id)
                selectLanguageModel(model.selectionID)
            }
        }
        .fileImporter(isPresented: $showingGGUFImporter,
                      allowedContentTypes: [UTType(filenameExtension: "gguf") ?? .data]) { result in
            importGGUF(result)
        }
        .confirmationDialog("允许使用网络模型？", isPresented: $showingNetworkPrivacyConfirmation, titleVisibility: .visible) {
            Button("允许并使用") {
                guard let model = pendingNetworkModel else { return }
                ExternalModelPrivacyApprovalStore.approve(model.id)
                selectedLanguageModelID = model.selectionID
                pendingNetworkModel = nil
            }
            Button("取消", role: .cancel) { pendingNetworkModel = nil }
        } message: {
            Text("点界会把当前任务所需的文字内容发送到 \(pendingNetworkModel?.name ?? "网络服务")。内容不会先经过点界服务器，也不会在未经确认时自动切换到其他云端模型。")
        }
    }

    private func speechName(_ manifest: ModelManifest) -> String {
        switch manifest.id {
        case ModelManifest.whisperTinyQ5.id: return "Whisper tiny Q5_1"
        case ModelManifest.whisperSmallQ5.id: return "Whisper small Q5_1"
        default: return "Whisper base Q5_1"
        }
    }

    private func languageName(_ manifest: ModelManifest) -> String {
        switch manifest.id {
        case ModelManifest.qwen3_1_7BQ8.id: return "Qwen3 1.7B Q8_0"
        case ModelManifest.qwen3VL2BQ8.id: return "Qwen3-VL 2B Q8_0"
        default: return "Qwen3 0.6B Q8_0"
        }
    }

    private func languageExplanation(_ manifest: ModelManifest) -> String {
        switch manifest.id {
        case ModelManifest.qwen3_1_7BQ8.id:
            return "标题和对话质量更高，需要较新的设备并占用更多内存。"
        case ModelManifest.qwen3VL2BQ8.id:
            return "同时用于图片理解和本地整理；整理纯文本时不加载视觉投影文件。"
        default:
            return "体积较小、速度较快，适合日常标题和简短对话。"
        }
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

    private func selectLanguageModel(_ selectionID: String) {
        guard let model = externalModels.first(where: { $0.selectionID == selectionID }),
              model.kind == .openAICompatible,
              !ExternalModelPrivacyApprovalStore.isApproved(model.id) else {
            selectedLanguageModelID = selectionID
            return
        }
        pendingNetworkModel = model
        showingNetworkPrivacyConfirmation = true
    }

    private func testConnection(_ model: ExternalLanguageModel) {
        testingModelID = model.id
        connectionResult = nil
        externalModelError = nil
        Task {
            do {
                let reply = try await ExternalModelConnectionTester.test(model: model)
                connectionResult = "连接成功：\(reply)"
            } catch {
                externalModelError = "连接失败：\(error.localizedDescription)"
            }
            testingModelID = nil
        }
    }

    private func importGGUF(_ result: Result<URL, Error>) {
        guard case .success(let source) = result else {
            if case .failure(let error) = result { externalModelError = error.localizedDescription }
            return
        }
        isImportingGGUF = true
        Task {
            do {
                let model = try await Task.detached(priority: .utility) {
                    let scoped = source.startAccessingSecurityScopedResource()
                    defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                    let root = try AudioBlobStore.applicationSupportRoot()
                        .appending(path: "models/external", directoryHint: .isDirectory)
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    let id = UUID()
                    let destination = root.appending(path: id.uuidString + ".gguf")
                    try FileManager.default.copyItem(at: source, to: destination)
                    return ExternalLanguageModel(id: id, name: source.deletingPathExtension().lastPathComponent,
                                                 kind: .localGGUF, localPath: destination.path)
                }.value
                externalModels.append(model)
                ExternalLanguageModelStore.save(externalModels)
                selectedLanguageModelID = model.selectionID
                externalModelError = nil
            } catch { externalModelError = error.localizedDescription }
            isImportingGGUF = false
        }
    }

    private func removeExternalModel(_ model: ExternalLanguageModel) {
        if let path = model.localPath { try? FileManager.default.removeItem(atPath: path) }
        ExternalModelAPIKeyStore.remove(modelID: model.id)
        ExternalModelPrivacyApprovalStore.revoke(model.id)
        externalModels.removeAll { $0.id == model.id }
        ExternalLanguageModelStore.save(externalModels)
        if selectedLanguageModelID == model.selectionID { selectedLanguageModelID = ModelSelection.disabledLanguageModelID }
    }
}

private struct NetworkModelEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var provider = ExternalLanguageModelProvider.openRouter
    @State private var name = "OpenRouter"
    @State private var baseURL = ExternalLanguageModelProvider.openRouter.defaultBaseURL
    @State private var modelName = ExternalLanguageModelProvider.openRouter.suggestedModel
    @State private var apiKey = ""
    @State private var isTesting = false
    @State private var testResult: String?
    @State private var testError: String?
    let onSave: (ExternalLanguageModel, String) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Picker("服务商", selection: $provider) {
                    ForEach(ExternalLanguageModelProvider.allCases, id: \.self) { provider in
                        Text(verbatim: provider.displayName).tag(provider)
                    }
                }
                .onChange(of: provider) { _, value in
                    name = value.displayName
                    baseURL = value.defaultBaseURL
                    if modelName.isEmpty || modelName == "openrouter/free" { modelName = value.suggestedModel }
                    testResult = nil
                    testError = nil
                }
                TextField("名称", text: $name)
                TextField("Base URL", text: $baseURL).textInputAutocapitalization(.never).keyboardType(.URL)
                TextField("模型名称", text: $modelName).textInputAutocapitalization(.never)
                SecureField("API Key（可选）", text: $apiKey)
                Button {
                    testCurrentConfiguration()
                } label: {
                    HStack {
                        if isTesting { ProgressView().controlSize(.small) }
                        Text("测试连接")
                    }
                }
                .disabled(!isValid || isTesting)
                if let testResult { Text(verbatim: testResult).font(.footnote).foregroundStyle(.green) }
                if let testError { Text(verbatim: testError).font(.footnote).foregroundStyle(.red) }
                Section {
                    Text("测试只发送固定文字“PointVerse OK”。保存并选择模型后，点界会再次请求你确认是否允许发送真实内容。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("添加网络模型")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let model = ExternalLanguageModel(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                                          kind: .openAICompatible,
                                                          provider: provider,
                                                          baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                                                          remoteModel: modelName.trimmingCharacters(in: .whitespacesAndNewlines))
                        onSave(model, apiKey)
                        dismiss()
                    }.disabled(!isValid)
                }
            }
        }
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        URL(string: baseURL)?.scheme?.hasPrefix("http") == true
    }

    private func testCurrentConfiguration() {
        let model = ExternalLanguageModel(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                          kind: .openAICompatible,
                                          provider: provider,
                                          baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                                          remoteModel: modelName.trimmingCharacters(in: .whitespacesAndNewlines))
        isTesting = true
        testResult = nil
        testError = nil
        Task {
            do {
                let reply = try await ExternalModelConnectionTester.test(model: model, apiKey: apiKey)
                testResult = "连接成功：\(reply)"
            } catch {
                testError = error.localizedDescription
            }
            isTesting = false
        }
    }
}

private struct Edge0ModelRow: View {
    @ObservedObject var manager: Edge0DownloadManager
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: "Edge0 8B A1B · Experimental")
                    Text(verbatim: ByteCountFormatter.string(fromByteCount: Edge0Model8B.totalByteCount, countStyle: .file) + " · Apache-2.0")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                status
            }
            switch manager.state {
            case .checking, .verifying:
                ProgressView().controlSize(.small)
            case .notInstalled, .failed:
                Button("下载模型") { manager.download() }
            case .downloading(let progress):
                ProgressView(value: progress)
                HStack {
                    Text(progress, format: .percent.precision(.fractionLength(0))).font(.caption).monospacedDigit()
                    Spacer()
                    Button("暂停") { manager.cancel() }.buttonStyle(.borderless)
                }
            case .installed:
                HStack {
                    if isSelected {
                        Label("使用中", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("使用此模型", action: onSelect).buttonStyle(.borderless)
                    }
                    Spacer()
                    Button("卸载模型", role: .destructive) { manager.remove() }.buttonStyle(.borderless)
                }
            }
            Text("高质量本地理解实验后端，用于标题、对话和测试文本。约 4.6 GB，仅支持真机 Metal；不替代 E5 语义向量模型。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .task { await manager.refresh() }
    }

    @ViewBuilder private var status: some View {
        switch manager.state {
        case .checking: Text("检查中")
        case .notInstalled: Text("未安装")
        case .downloading: Text("下载中")
        case .verifying: Text("正在校验")
        case .installed: Text("已安装").foregroundStyle(.green)
        case .failed(let error):
            Text(error == .modelChecksumMismatch ? "校验失败" : error == .insufficientDiskSpace ? "空间不足" : "下载失败").foregroundStyle(.red)
        }
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
    var onRemoved: () -> Void = {}
    var canSelect = true
    @State private var wasInstalled = false

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
            if wasInstalled, state == .notInstalled { onRemoved() }
            wasInstalled = state == .installed
        }
        .onAppear { wasInstalled = manager.state == .installed }
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
        if !canSelect {
            AppText("已安装").foregroundStyle(.green)
        } else if isSelected {
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
