import SwiftUI

@main
struct PointVerseApp: App {
    @UIApplicationDelegateAdaptor(PointVerseAppDelegate.self) private var appDelegate
    @StateObject private var container = AppContainer()
    @StateObject private var testContainer = AppContainer(storageMode: .test)
    @AppStorage("appLanguage") private var appLanguage = "system"
    @State private var isTestMode = false

    var body: some Scene {
        WindowGroup {
            RootView(isTestMode: $isTestMode)
                .environmentObject(isTestMode ? testContainer : container)
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
                        container.startWatchConnectivity()
                        await container.prepare()
                    }
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

    var body: some View {
        TabView {
            NavigationStack { CaptureView() }
                .tabItem { Label { AppText("记录") } icon: { Image(systemName: "waveform.circle.fill") } }
            NavigationStack { StarMapView() }
                .tabItem { Label { AppText("星图") } icon: { Image(systemName: "sparkles") } }
            NavigationStack { GlobeMapView() }
                .tabItem { Label { AppText("星球") } icon: { Image(systemName: "globe.asia.australia.fill") } }
            NavigationStack { PointListView() }
                .tabItem { Label { AppText("想法") } icon: { Image(systemName: "circle.grid.2x2.fill") } }
            NavigationStack { ImageGenerationView() }
                .tabItem { Label { AppText("图片") } icon: { Image(systemName: "photo.badge.plus") } }
            NavigationStack { ModelSettingsView() }
                .tabItem { Label { AppText("模型") } icon: { Image(systemName: "cpu") } }
        }
        .id("\(isTestMode)-\(testDataRevision)")
        .tint(.indigo)
        .safeAreaInset(edge: .top, spacing: 0) {
            if isTestMode {
                HStack(spacing: 12) {
                    Label("测试模式 · 独立数据库", systemImage: "flask.fill")
                        .font(.caption.bold())
                    Spacer()
                    Text("\(testPointCount) 条").font(.caption.monospacedDigit())
                    Button("+100") {
                        Task { await generateTestData() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.purple)
                    .disabled(isGeneratingTestData)
                    if isGeneratingTestData { ProgressView().tint(.white).controlSize(.small) }
                    Button("退出") { isTestMode = false }
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .foregroundStyle(.white)
                .background(Color.purple)
            }
        }
        .task(id: isTestMode) {
            guard isTestMode else { return }
            testPointCount = (try? await container.database.listPoints(matching: "").count) ?? 0
        }
    }

    private func generateTestData() async {
        guard isTestMode, !isGeneratingTestData else { return }
        isGeneratingTestData = true
        defer { isGeneratingTestData = false }
        testPointCount = (try? await container.appendGeneratedTestTexts(count: 100)) ?? testPointCount
        testDataRevision += 1
    }
}
