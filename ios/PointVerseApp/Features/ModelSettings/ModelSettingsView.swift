import PointVerseKit
import QwenAdapter
import SwiftUI
import UniformTypeIdentifiers

struct ModelSettingsView: View {
    @AppStorage("appLanguage") private var appLanguage = "system"
    @AppStorage(ModelSelection.speechDefaultsKey) private var selectedSpeechModelID = ModelManifest.whisperBaseQ5.id
    @AppStorage(ModelSelection.languageDefaultsKey) private var selectedLanguageModelID = ModelSelection.pointVerseCloudLanguageModelID
    @AppStorage(ModelSelection.imageDefaultsKey) private var selectedImageModelID = ModelManifest.stableDiffusion21Base6Bit.id
    @AppStorage("selectedExternalModel.imageGeneration") private var imageGenerationRoute = "local"
    @AppStorage("selectedExternalModel.embedding") private var embeddingRoute = "local"
    @AppStorage("selectedExternalModel.vision") private var visionRoute = "local"
    @AppStorage("selectedExternalModel.speech") private var speechRoute = "local"
    @AppStorage("selectedExternalModel.audioUnderstanding") private var audioUnderstandingRoute = "local"
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var account: AccountSessionStore
    @State private var externalModels = ExternalLanguageModelStore.load()
    @State private var showingNetworkModelEditor = false
    @State private var showingGGUFImporter = false
    @State private var isImportingGGUF = false
    @State private var externalModelError: String?
    @State private var pendingNetworkModel: ExternalLanguageModel?
    @State private var showingNetworkPrivacyConfirmation = false
    @State private var pendingCapability: ExternalModelCapability = .language
    @State private var testingModelID: UUID?
    @State private var connectionResult: String?
    @State private var showingPlanetDistributionDemo = false
    @AppStorage(AppNetworkPolicy.modeKey) private var usageMode = AppUsageMode.privacy.rawValue
    @AppStorage(AppNetworkPolicy.acquisitionKey) private var acquisition = LocalModelAcquisition.browser.rawValue
    @AppStorage(AppNetworkPolicy.offlineBackupKey) private var offlineBackup = false
    @AppStorage(AppNetworkPolicy.offlineModelKey) private var offlineModel = ModelManifest.qwen3VL2BQ8.id
    @State private var showingLocalModels = false
    @State private var showingEmbeddingDescriptorImport = false
    private var isCloud: Bool { usageMode == AppUsageMode.cloud.rawValue }

    private var selectedExternalModel: ExternalLanguageModel? {
        externalModels.first { $0.selectionID == selectedLanguageModelID }
    }

    private var currentAssistantName: String {
        if selectedLanguageModelID == ModelSelection.disabledLanguageModelID { return "未启用" }
        if selectedLanguageModelID == ModelSelection.pointVerseCloudLanguageModelID { return "点界云端 AI · 快速" }
        if selectedLanguageModelID == ModelSelection.pointVerseCloudEnhancedModelID { return "点界云端 AI · 增强" }
        if selectedLanguageModelID == ModelSelection.edge0LanguageModelID { return "Edge0 8B A1B" }
        if let model = selectedExternalModel { return model.name }
        if let manifest = ModelSelection.languageModels.first(where: { $0.id == selectedLanguageModelID }) {
            return languageName(manifest)
        }
        return "未启用"
    }

    private var currentAssistantLocation: String {
        guard let model = selectedExternalModel else {
            if ModelSelection.isPointVerseCloud(selectedLanguageModelID) {
                return account.session == nil ? "登录点界后可用" : "由点界私有计算节点运行"
            }
            return selectedLanguageModelID == ModelSelection.disabledLanguageModelID ? "不会生成标题或对话回复" : "在这台设备上运行 · 内容不离开设备"
        }
        return model.kind == .openAICompatible
            ? "通过 \(model.provider?.displayName ?? "网络服务") 运行 · 内容会发送给服务商"
            : "使用导入的 GGUF 文件 · 在这台设备上运行"
    }

    var body: some View {
        List {
            AppModeControls()
            if let externalModelError { Text(externalModelError).font(.footnote).foregroundStyle(.red) }
            if isCloud && container.storageMode == .production {
                Section {
                    NavigationLink { AccountView(library: .init(database: container.database, audio: container.blobStore, images: container.imageBlobStore)) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(.indigo)
                            VStack(alignment: .leading, spacing: 3) {
                                AppText(account.user == nil ? "登录点界" : "我的账户").font(.headline)
                                if let user = account.user {
                                    Text(verbatim: user.displayName.isEmpty ? (user.identities.first?.email ?? "PointVerse") : user.displayName)
                                        .font(.caption).foregroundStyle(.secondary)
                                } else {
                                    AppText("通过 Apple 或 Google 登录").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.padding(.vertical, 4)
                    }
                } header: { AppText("账户") }
            }
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
                CurrentAssistantCard(
                    name: currentAssistantName,
                    detail: currentAssistantLocation,
                    isNetwork: ModelSelection.isPointVerseCloud(selectedLanguageModelID) || selectedExternalModel?.kind == .openAICompatible
                )

                Picker(selection: Binding(get: { selectedLanguageModelID }, set: selectLanguageModel)) {
                    AppText("关闭 AI 助手").tag(ModelSelection.disabledLanguageModelID)
                    if isCloud {
                    Section("点界") {
                        Text(verbatim: "点界云端 AI · 快速 · 默认（Qwen3.5 4B）").tag(ModelSelection.pointVerseCloudLanguageModelID)
                        Text(verbatim: "点界云端 AI · 增强（Qwen3.5 9B）").tag(ModelSelection.pointVerseCloudEnhancedModelID)
                    }
                    Section("已安装的本地模型") {
                        ForEach(container.languageModelManagers.filter { $0.state == .installed }, id: \.manifest.id) { manager in
                            Text(verbatim: languageName(manager.manifest)).tag(manager.manifest.id)
                        }
                        ForEach(externalModels.filter { $0.kind == .localGGUF }) { model in
                            Text(verbatim: model.name).tag(model.selectionID)
                        }
                    }
                    } else {
                    Section("设备端") {
                        ForEach(ModelSelection.languageModels, id: \.id) { manifest in
                            Text(verbatim: languageName(manifest)).tag(manifest.id)
                        }
                        if acquisition == LocalModelAcquisition.inApp.rawValue {
                            Text(verbatim: "Edge0 8B A1B · Experimental").tag(ModelSelection.edge0LanguageModelID)
                        }
                        ForEach(externalModels.filter { $0.kind == .localGGUF }) { model in
                            Text(verbatim: model.name).tag(model.selectionID)
                        }
                    }
                    }
                } label: { AppText("切换 AI 助手") }
            } header: { AppText("当前 AI 助手") }
              footer: { Text("用于自动标题、内容整理、对话和测试数据生成。语义坐标仍由独立的 E5 模型计算。") }

            if isCloud {
                Section {
                    Label("无需下载本地模型", systemImage: "cloud")
                    Label("图片理解 · Qwen3.5", systemImage: "photo")
                    Picker("图片生成", selection: $imageGenerationRoute) {
                        Text("点界云端 · Stable Diffusion 1.5").tag("pointverse-cloud")
                        Text("本地模型 · 需已安装").tag("local")
                    }
                    Text("云端生图为 512×512，支持中文描述，无需下载模型。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Picker("语音转写", selection: $speechRoute) {
                        Text("点界云端语音识别").tag("pointverse-cloud")
                        Text("Apple 系统识别 · 本机").tag("local")
                    }
                    Text("云端语音转写支持 30 分钟以内的录音；图片会压缩后发送。历史图片不会自动上传分析。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("登录后使用点界云端快速或增强模型。只有你主动发起的 AI 请求会发送相关内容；已有资料不会自动上传。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("其他云端能力仍在接入中。也可按需使用本地模型，不会自动下载。")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: { Text("云端服务") }
                Section {
                    DisclosureGroup("离线备用（可选）", isExpanded: $showingLocalModels) {
                        Toggle("断网时使用已安装的本地聊天模型", isOn: $offlineBackup)
                        if offlineBackup {
                            Picker("备用模型", selection: $offlineModel) {
                                ForEach(container.languageModelManagers, id: \.manifest.id) { manager in
                                    Text(verbatim: languageName(manager.manifest) + (manager.state == .installed ? " · 已安装" : " · 未安装")).tag(manager.manifest.id)
                                }
                            }
                            ModelAcquisitionControls()
                        }
                        Text("无需为使用云端模型下载任何文件。备用模型未安装时不会自动下载，也不会在服务器错误时擅自切换。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            if !isCloud || showingLocalModels {
            Section {
                ForEach(container.languageModelManagers, id: \.manifest.id) { manager in
                    ModelRow(manager: manager, name: languageName(manager.manifest), metadata: metadata(manager.manifest), explanation: languageExplanation(manager.manifest), isSelected: selectedLanguageModelID == manager.manifest.id, onSelect: {
                        selectedLanguageModelID = manager.manifest.id
                    }, onInstalled: regenerateTitles)
                }

                if acquisition == LocalModelAcquisition.inApp.rawValue {
                Edge0ModelRow(
                    manager: container.edge0ModelManager,
                    isSelected: selectedLanguageModelID == ModelSelection.edge0LanguageModelID,
                    onSelect: { selectedLanguageModelID = ModelSelection.edge0LanguageModelID }
                )
                }
            } header: { AppText("设备端语言模型") }
              footer: { Text("所有模型均在本机运行。可以选择对应模型文件导入；强隐私方式只在外部浏览器中下载。") }

            Section {
                Button { showingGGUFImporter = true } label: {
                    Label("导入本地 GGUF", systemImage: "square.and.arrow.down")
                }.disabled(isImportingGGUF)
                if isImportingGGUF { HStack { ProgressView(); Text("正在复制本地模型…") } }
                ForEach(externalModels.filter { $0.kind == .localGGUF }) { model in
                    ExternalModelRow(model: model,
                                     isSelected: selectedLanguageModelID == model.selectionID,
                                     isTesting: false,
                                     onSelect: { selectLanguageModel(model.selectionID) },
                                     onTest: {},
                                     onRemove: { removeExternalModel(model) })
                }
            } header: { AppText("导入的设备端模型") }
              footer: { Text("GGUF 文件会复制到点界的模型目录。兼容性取决于模型架构和当前推理引擎。") }

            Section {
                Picker(selection: $selectedSpeechModelID) {
                    ForEach(ModelSelection.speechModels, id: \.id) { manifest in
                        Text(verbatim: speechName(manifest)).tag(manifest.id)
                    }
                } label: { AppText("语音转写模型") }

                ForEach(container.speechModelManagers, id: \.manifest.id) { manager in
                    ModelRow(manager: manager, name: speechName(manager.manifest), metadata: metadata(manager.manifest), explanation: speechExplanation(manager.manifest), isSelected: selectedSpeechModelID == manager.manifest.id) {
                        selectedSpeechModelID = manager.manifest.id
                    }
                }
            } header: { AppText("语音转写") }

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
                if acquisition == LocalModelAcquisition.browser.rawValue {
                    Button("导入 E5 描述文件") { showingEmbeddingDescriptorImport = true }
                    Link("浏览器下载 E5 描述文件", destination: URL(string: "https://huggingface.co/tuanda2912/hark-multilingual-e5-small-coreml/resolve/\(ModelManifest.harkMultilingualE5Small.revision)/MultilingualE5Small.mlpackage/Data/com.apple.CoreML/model.mlmodel?download=true")!)
                    Text("强隐私方式需同时导入权重和描述文件，点界不会自动联网补齐。")
                        .font(.footnote).foregroundStyle(.secondary)
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
            if acquisition == LocalModelAcquisition.inApp.rawValue {
                Section {
                    RecordingModelsPanel(manager: container.recordingModelManager)
                } header: { Text("说话人与声音状态 · 本地识别") }
            }
            }

            Section {
                DisclosureGroup("实验工具") {
                Button {
                    NotificationCenter.default.post(name: AppContainer.enterTestMode, object: nil)
                } label: {
                    Label("进入独立测试模式", systemImage: "flask.fill")
                }

                Button {
                    showingPlanetDistributionDemo = true
                } label: {
                    Label("球面分布演示", systemImage: "globe.asia.australia.fill")
                }
                }
            } header: {
                AppText("高级")
            } footer: {
                Text("测试模式使用独立数据库；球面分布演示使用内置样本，不影响正式内容。")
            }

        }
        .navigationTitle("模式与模型")
        .onChange(of: speechRoute) { _, _ in UserDefaults.standard.set(true, forKey: "pointverse.cloudSpeechConfigured") }
        .onChange(of: offlineBackup) { _, _ in container.applyNetworkPolicy() }
        .fileImporter(isPresented: $showingEmbeddingDescriptorImport, allowedContentTypes: [.data]) { result in
            if case .success(let url) = result {
                Task {
                    do { try await container.importEmbeddingDescriptor(url) }
                    catch { externalModelError = error.localizedDescription }
                }
            }
        }
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
        .sheet(isPresented: $showingPlanetDistributionDemo) {
            NavigationStack { PlanetDistributionDemoView() }
        }
        .fileImporter(isPresented: $showingGGUFImporter,
                      allowedContentTypes: [UTType(filenameExtension: "gguf") ?? .data]) { result in
            importGGUF(result)
        }
        .confirmationDialog("允许使用网络模型？", isPresented: $showingNetworkPrivacyConfirmation, titleVisibility: .visible) {
            Button("允许并使用") {
                guard let model = pendingNetworkModel else { return }
                ExternalModelPrivacyApprovalStore.approve(model.id)
                applySelection(model.selectionID, for: pendingCapability)
                pendingNetworkModel = nil
            }
            Button("取消", role: .cancel) { pendingNetworkModel = nil }
        } message: {
            Text(privacyMessage)
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
        guard !ModelSelection.isPointVerseCloud(selectedLanguageModelID) else { return }
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
        pendingCapability = .language
        showingNetworkPrivacyConfirmation = true
    }

    private func selectCapability(_ capability: ExternalModelCapability, selectionID: String) {
        guard selectionID != "local",
              let model = externalModels.first(where: { $0.selectionID == selectionID }) else {
            applySelection("local", for: capability)
            return
        }
        guard ExternalModelPrivacyApprovalStore.isApproved(model.id) else {
            pendingNetworkModel = model
            pendingCapability = capability
            showingNetworkPrivacyConfirmation = true
            return
        }
        applySelection(selectionID, for: capability)
    }

    private func applySelection(_ selectionID: String, for capability: ExternalModelCapability) {
        switch capability {
        case .language: selectedLanguageModelID = selectionID
        case .imageGeneration: imageGenerationRoute = selectionID
        case .embedding: embeddingRoute = selectionID
        case .vision: visionRoute = selectionID
        case .speech: speechRoute = selectionID
        case .audioUnderstanding: audioUnderstandingRoute = selectionID
        }
    }

    private var privacyMessage: String {
        let content: String
        switch pendingCapability {
        case .language: content = "当前任务所需的文字"
        case .imageGeneration: content = "生图提示词"
        case .embedding: content = "用于建立语义坐标的文字"
        case .vision: content = "所选图片和相关文字"
        case .speech: content = "录音内容"
        case .audioUnderstanding: content = "音乐或现场声音"
        }
        return "点界会把\(content)发送到 \(pendingNetworkModel?.name ?? "网络服务")。内容不会先经过点界服务器，也不会自动切换到其他云端模型。"
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

struct AppModeControls: View {
    var onboarding = false
    @EnvironmentObject private var account: AccountSessionStore
    @EnvironmentObject private var container: AppContainer
    @AppStorage(AppNetworkPolicy.modeKey) private var mode = AppUsageMode.privacy.rawValue
    @AppStorage(AppNetworkPolicy.configuredKey) private var chosen = false
    @AppStorage(ModelSelection.languageDefaultsKey) private var selectedModel = ModelSelection.pointVerseCloudLanguageModelID
    @State private var pendingMode: String?

    var body: some View {
        Section {
            if onboarding {
                Text("先选择你的使用方式，之后可以在这里切换。").font(.headline)
                Button { choose(AppUsageMode.privacy.rawValue) } label: {
                    Label("使用隐私版", systemImage: "lock.shield")
                }
                Text("不登录，不使用网络模型，内容在本机处理。默认采用强隐私方式获取模型。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button { choose(AppUsageMode.cloud.rawValue) } label: {
                    Label("使用登录版", systemImage: "cloud")
                }
                Text("登录使用云端 AI，无需安装模型。也可按需准备本地离线备用。")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Picker("使用方式", selection: Binding(get: { mode }, set: { pendingMode = $0 })) {
                    Text("隐私版").tag(AppUsageMode.privacy.rawValue)
                    Text("登录版").tag(AppUsageMode.cloud.rawValue)
                }
                if mode == AppUsageMode.privacy.rawValue { ModelAcquisitionControls() }
                else { Text("云端优先 · 本地备用可选").font(.footnote).foregroundStyle(.secondary) }
            }
        } header: { Text("使用方式") }
          footer: { Text("切换不会删除本机资料，也不会自动上传已有内容。切回隐私版会清除本机登录状态；已上传的云端资料需单独管理。") }
          .disabled(account.isBusy || account.isSyncing)
          .confirmationDialog("切换使用方式？", isPresented: Binding(get: { pendingMode != nil }, set: { if !$0 { pendingMode = nil } }), titleVisibility: .visible) {
              Button("确认切换") { if let pendingMode { choose(pendingMode) }; pendingMode = nil }
              Button("取消", role: .cancel) { pendingMode = nil }
          } message: {
              Text(pendingMode == AppUsageMode.cloud.rawValue
                   ? "登录版允许登录、云端 AI 和手动云同步。已有资料不会因切换而上传。"
                   : "隐私版会停止网络模型和云同步，并清除本机登录状态。")
          }
    }

    private func choose(_ value: String) {
        guard !account.isBusy, !account.isSyncing else { return }
        // Cancel shared AI requests before applying the new routing policy.
        URLSession.shared.getAllTasks { $0.forEach { $0.cancel() } }
        mode = value
        if value == AppUsageMode.privacy.rawValue {
            for capability in ["imageGeneration", "embedding", "vision", "speech", "audioUnderstanding"] {
                UserDefaults.standard.set("local", forKey: "selectedExternalModel.\(capability)")
            }
        }
        if value == AppUsageMode.cloud.rawValue {
            selectedModel = ModelSelection.pointVerseCloudLanguageModelID
            UserDefaults.standard.set("pointverse-cloud", forKey: "selectedExternalModel.speech")
            UserDefaults.standard.set("pointverse-cloud", forKey: "selectedExternalModel.imageGeneration")
        } else if ModelSelection.isPointVerseCloud(selectedModel) || ExternalLanguageModelStore.load().contains(where: { $0.selectionID == selectedModel && $0.kind == .openAICompatible }) {
            selectedModel = ModelManifest.qwen3VL2BQ8.id
        }
        chosen = true
        account.applyUsageMode()
        container.applyNetworkPolicy()
    }
}

struct ModelAcquisitionControls: View {
    @AppStorage(AppNetworkPolicy.acquisitionKey) private var acquisition = LocalModelAcquisition.browser.rawValue
    @AppStorage(AppNetworkPolicy.modeKey) private var mode = AppUsageMode.privacy.rawValue
    @EnvironmentObject private var container: AppContainer
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("模型获取方式", selection: $acquisition) {
                Text(mode == AppUsageMode.privacy.rawValue ? "强隐私 · 浏览器下载后导入" : "浏览器下载后导入").tag(LocalModelAcquisition.browser.rawValue)
                Text("便捷 · 应用内断点续传").tag(LocalModelAcquisition.inApp.rawValue)
            }
            Text(mode == AppUsageMode.cloud.rawValue
                 ? "这里仅设置本地备用模型的获取方式，云端 AI 仍可联网。下载和导入均由你主动操作。"
                 : acquisition == LocalModelAcquisition.browser.rawValue
                 ? "点界不主动发起网络请求。下载链接在外部浏览器打开，再选择已下载到本机的文件导入。"
                 : "仅在你主动下载时联网获取模型，支持暂停和续传；不会上传录音、图片或聊天。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .onChange(of: acquisition) { _, value in
            if value == LocalModelAcquisition.browser.rawValue && AppNetworkPolicy.mode() == .privacy {
                URLSession.shared.getAllTasks { $0.forEach { $0.cancel() } }
            }
            container.applyNetworkPolicy()
        }
    }
}

private struct RecordingModelsPanel: View {
    @ObservedObject var manager: RecordingModelManager
    @AppStorage("automaticRecordingRecognition") private var automaticRecognition = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("打开录音详情时自动识别", isOn: $automaticRecognition)
            ForEach(RecordingModelKind.allCases) { kind in
                HStack {
                    VStack(alignment: .leading) {
                        Text(kind.title).font(.subheadline.bold())
                        Text(kind == .speaker ? "中文／英文声纹匹配 · Apache-2.0" : "中文等多语言情绪候选 · SenseVoice上游许可")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if manager.installed.contains(kind) {
                        Label("已下载", systemImage: "checkmark.circle").font(.caption)
                    } else {
                        Button(manager.downloading == kind ? "下载中…" : manager.pausedKind == kind ? "继续下载" : "下载") {
                            Task { await manager.download(kind) }
                        }.disabled(manager.downloading != nil)
                    }
                }
            }
            if manager.downloading != nil {
                ProgressView(value: manager.progress)
                HStack {
                    Text("\(Int(manager.progress * 100))% · \(ByteCountFormatter.string(fromByteCount: manager.receivedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: manager.totalBytes, countStyle: .file))")
                        .font(.caption.monospacedDigit())
                    Spacer()
                    Button("暂停") { manager.pause() }
                }
            }
            if !manager.phase.isEmpty { Text(manager.phase).font(.caption).foregroundStyle(.secondary) }
            if let error = manager.error { Text(error).font(.caption).foregroundStyle(.red) }
            Text("录音留在设备上，模型按需下载。详情页点自动识别；清晰单人讲话至少6秒，原型取开头片段。首次需手动确认说话人建立样本。")
                .font(.caption).foregroundStyle(.secondary)
        }.task { manager.refresh() }
    }
}

private struct CurrentAssistantCard: View {
    let name: String
    let detail: String
    let isNetwork: Bool

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill((isNetwork ? Color.blue : Color.indigo).gradient)
                    .frame(width: 48, height: 48)
                Image(systemName: isNetwork ? "cloud.fill" : "iphone.gen3")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: name).font(.headline)
                Text(verbatim: detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct CapabilityRoutePicker: View {
    let title: String
    let capability: ExternalModelCapability
    @Binding var selection: String
    let models: [ExternalLanguageModel]

    var body: some View {
        Picker(title, selection: $selection) {
            Label("设备端", systemImage: "iphone.gen3").tag("local")
            ForEach(models.filter { $0.kind == .openAICompatible && $0.supports(capability) }) { model in
                Label(model.name, systemImage: "cloud").tag(model.selectionID)
            }
        }
    }
}

private struct ExternalModelRow: View {
    let model: ExternalLanguageModel
    let isSelected: Bool
    let isTesting: Bool
    let onSelect: () -> Void
    let onTest: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Image(systemName: model.kind == .openAICompatible ? "cloud" : "externaldrive")
                    .foregroundStyle(model.kind == .openAICompatible ? .blue : .indigo)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: model.name)
                    Text(verbatim: subtitle).font(.caption).foregroundStyle(.secondary)
                    if model.kind == .openAICompatible {
                        Text(verbatim: model.supportedCapabilities.map(\.displayName).joined(separator: " · "))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isSelected {
                    Label("使用中", systemImage: "checkmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.green)
                }
            }
            HStack {
                if !isSelected {
                    Button("使用此模型", action: onSelect).buttonStyle(.borderless)
                }
                if model.kind == .openAICompatible {
                    Button(action: onTest) {
                        if isTesting { ProgressView().controlSize(.small) }
                        else { Label("测试连接", systemImage: "bolt.horizontal.circle") }
                    }
                    .disabled(isTesting)
                    .buttonStyle(.borderless)
                }
                Spacer()
                Button("移除", role: .destructive, action: onRemove).buttonStyle(.borderless)
            }
            .font(.subheadline)
        }
        .padding(.vertical, 3)
    }

    private var subtitle: String {
        if model.kind == .localGGUF { return "本地 GGUF" }
        let provider = model.provider?.displayName ?? "OpenAI-compatible"
        let remote = model.remoteModel?.isEmpty == false ? model.remoteModel! : "未指定模型"
        return "\(provider) · \(remote)"
    }
}

private struct NetworkModelEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var provider = ExternalLanguageModelProvider.openRouter
    @State private var name = "OpenRouter"
    @State private var baseURL = ExternalLanguageModelProvider.openRouter.defaultBaseURL
    @State private var modelName = ExternalLanguageModelProvider.openRouter.suggestedModel
    @State private var apiKey = ""
    @State private var capabilities: Set<ExternalModelCapability> = [.language]
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
                Section("用于") {
                    ForEach(ExternalModelCapability.allCases, id: \.self) { capability in
                        Toggle(capability.displayName, isOn: Binding(
                            get: { capabilities.contains(capability) },
                            set: { enabled in
                                if enabled { capabilities.insert(capability) }
                                else { capabilities.remove(capability) }
                            }
                        ))
                    }
                }
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
                                                          remoteModel: modelName.trimmingCharacters(in: .whitespacesAndNewlines),
                                                          capabilities: capabilities.sorted { $0.rawValue < $1.rawValue })
                        onSave(model, apiKey)
                        dismiss()
                    }.disabled(!isValid)
                }
            }
        }
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !capabilities.isEmpty &&
        !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        URL(string: baseURL)?.scheme?.hasPrefix("http") == true
    }

    private func testCurrentConfiguration() {
        let model = ExternalLanguageModel(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                          kind: .openAICompatible,
                                          provider: provider,
                                          baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                                          remoteModel: modelName.trimmingCharacters(in: .whitespacesAndNewlines),
                                          capabilities: capabilities.sorted { $0.rawValue < $1.rawValue })
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
    @State private var showingLocalImport = false
    @AppStorage(AppNetworkPolicy.acquisitionKey) private var acquisition = LocalModelAcquisition.browser.rawValue

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
                    Button(role: .cancel) { manager.cancel() } label: { AppText("暂停下载") }
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
                acquisitionButtons
            case .notInstalled:
                acquisitionButtons
            }

            AppText(explanation).font(.footnote).foregroundStyle(.secondary)
            if let error = manager.lastErrorDescription { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .onChange(of: manager.state) { _, state in
            if state == .installed { onInstalled() }
            if wasInstalled, state == .notInstalled { onRemoved() }
            wasInstalled = state == .installed
        }
        .onAppear { wasInstalled = manager.state == .installed }
        .fileImporter(isPresented: $showingLocalImport, allowedContentTypes: [.data, .archive]) { result in
            if case .success(let url) = result { Task { await manager.importLocalFile(url) } }
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

    @ViewBuilder private var acquisitionButtons: some View {
        HStack {
            Button("选择本地模型文件") { showingLocalImport = true }.buttonStyle(.borderless)
            if acquisition == LocalModelAcquisition.browser.rawValue {
                Link("浏览器下载", destination: manager.manifest.downloadURL).font(.caption)
            } else {
                Button("应用内下载") { manager.download() }.buttonStyle(.borderless)
            }
        }
        Text("对应文件：\(manager.manifest.filename)").font(.caption2).foregroundStyle(.secondary)
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
            AppText(error == .modelChecksumMismatch ? "校验失败" : error == .insufficientDiskSpace ? "空间不足" : "未就绪").foregroundStyle(.red)
        }
    }
}
