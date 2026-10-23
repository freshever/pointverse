import SwiftUI
import GoogleSignIn

@main
struct PointVerseApp: App {
    @UIApplicationDelegateAdaptor(PointVerseAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var container = AppContainer()
    @StateObject private var testContainer = AppContainer(storageMode: .test)
    @StateObject private var account = AccountSessionStore()
    @AppStorage("appLanguage") private var appLanguage = "system"
    @State private var isTestMode = false

    var body: some Scene {
        WindowGroup {
            RootView(isTestMode: $isTestMode)
                .environmentObject(isTestMode ? testContainer : container)
                .environmentObject(account)
                .onOpenURL { url in _ = GIDSignIn.sharedInstance.handle(url) }
                .environment(\.appLanguage, appLanguage)
                .environment(\.locale, displayLocale)
                .id(appLanguage)
                .onReceive(NotificationCenter.default.publisher(for: AppContainer.enterTestMode)) { _ in
                    isTestMode = true
                }
                .task(id: isTestMode) {
                    if isTestMode {
                        await testContainer.prepare()
                    } else {
                        await container.prepare()
                        // Do not accept a Watch transfer until migrations and
                        // pending-task recovery have finished. A file can be
                        // delivered immediately when WCSession activates.
                        container.startWatchConnectivity()
                    }
                }
                .task(id: account.session?.accessToken) {
                    await container.configurePointVerseCloud(
                        baseURL: account.serviceURL,
                        accessToken: account.session?.accessToken
                    )
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active, !isTestMode else { return }
                    // A Watch recording may have arrived during a short
                    // background window in which Speech was unavailable.
                    // Retry resumable transcription as soon as the phone app
                    // becomes active instead of waiting for another launch.
                    Task { await container.transcriptionService.resumePending() }
                }
        }
    }

    private var displayLocale: Locale {
        appLanguage == "system" ? .autoupdatingCurrent : Locale(identifier: appLanguage)
    }
}

private struct RootView: View {
    @Binding var isTestMode: Bool
    @EnvironmentObject private var container: AppContainer
    @State private var isGeneratingTestData = false
    @State private var testPointCount = 0
    @State private var testDataRevision = 0
    @State private var testDataError: String?
    @State private var showingMemoryGenerationResult = false
    @State private var confirmingClearTestData = false

    var body: some View {
        VStack(spacing: 0) {
            if isTestMode { testModeBanner }
            TabView {
                NavigationStack { CaptureView() }
                    .tabItem { Label { AppText("记录") } icon: { Image(systemName: "waveform.circle.fill") } }
                NavigationStack { PointListView() }
                    .tabItem { Label { AppText("想法") } icon: { Image(systemName: "circle.grid.2x2.fill") } }
                NavigationStack { UniverseMapView() }
                    .tabItem { Label { AppText("宇宙") } icon: { Image(systemName: "hurricane") } }
                NavigationStack { ImageGenerationView() }
                    .tabItem { Label { AppText("图片") } icon: { Image(systemName: "photo.badge.plus") } }
                NavigationStack { ModelSettingsView() }
                    .tabItem { Label { AppText("模型") } icon: { Image(systemName: "cpu") } }
            }
        }
        .id("\(isTestMode)-\(testDataRevision)")
        .tint(.indigo)
        .task(id: isTestMode) {
            guard isTestMode else { return }
            testPointCount = (try? await container.database.listPoints(matching: "").count) ?? 0
        }
        .alert("测试数据操作失败", isPresented: Binding(get: { testDataError != nil }, set: { if !$0 { testDataError = nil } })) {
            Button("好") { testDataError = nil }
        } message: { Text(testDataError ?? "") }
        .alert("回忆样本已准备好", isPresented: $showingMemoryGenerationResult) {
            Button("好") { }
        } message: {
            Text(container.memoryTestGenerationStatus + "\n打开宇宙，点击星球，再选择开始回忆。")
        }
        .confirmationDialog("清除全部测试数据？", isPresented: $confirmingClearTestData, titleVisibility: .visible) {
            Button("清除测试数据", role: .destructive) { Task { await clearTestData() } }
            Button("取消", role: .cancel) { }
        } message: {
            Text("仅清除独立测试数据库中的想法、关系、回忆记录及附件。正式用户资料和下载的模型不会删除。此操作无法撤销。")
        }
    }

    // Reserve real layout space above the TabView. An inset on the outer
    // TabView can overlap child NavigationStack toolbars on iPhone-on-Mac.
    private var testModeBanner: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Label("测试模式 · 独立数据库", systemImage: "flask.fill")
                    .font(.caption.bold())
                Spacer(minLength: 4)
                Text("\(testPointCount) 条").font(.caption.monospacedDigit())
                Button("退出") { isTestMode = false }
                    .disabled(isGeneratingTestData)
                    .font(.caption.bold())
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    Button("+100") { Task { await generateTestData() } }
                        .buttonStyle(.borderedProminent)
                        .tint(.white)
                        .foregroundStyle(.purple)
                    Button("回忆样本") { Task { await generateMemoryData() } }
                        .buttonStyle(.bordered)
                    Button { confirmingClearTestData = true } label: {
                        Label("清除测试数据", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    if isGeneratingTestData { ProgressView().tint(.white).controlSize(.small) }
                }
                .fixedSize(horizontal: true, vertical: false)
                .disabled(isGeneratingTestData)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .foregroundStyle(.white)
        .tint(.white)
        .background(Color.purple)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func generateTestData() async {
        guard isTestMode, !isGeneratingTestData else { return }
        isGeneratingTestData = true
        defer { isGeneratingTestData = false }
        testPointCount = (try? await container.appendGeneratedTestTexts(count: 100)) ?? testPointCount
        testDataRevision += 1
    }

    private func generateMemoryData() async {
        guard isTestMode, !isGeneratingTestData else { return }
        isGeneratingTestData = true
        defer { isGeneratingTestData = false }
        do {
            testPointCount = try await container.appendMemoryTestTexts()
            testDataRevision += 1
            showingMemoryGenerationResult = true
        } catch { testDataError = error.localizedDescription }
    }

    private func clearTestData() async {
        guard isTestMode, container.storageMode == .test, !isGeneratingTestData else { return }
        isGeneratingTestData = true
        defer { isGeneratingTestData = false }
        do {
            try await container.clearTestData()
            testPointCount = 0
        } catch {
            testDataError = error.localizedDescription
            testPointCount = (try? await container.database.listPoints(matching: "").count) ?? testPointCount
        }
        testDataRevision += 1
    }
}
