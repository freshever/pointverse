import SwiftUI

@main
struct PointVerseApp: App {
    @StateObject private var container = AppContainer()
    @AppStorage("appLanguage") private var appLanguage = "system"

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(container)
                .environment(\.appLanguage, appLanguage)
                .environment(\.locale, displayLocale)
                .id(appLanguage)
                .task { await container.prepare() }
        }
    }

    private var displayLocale: Locale {
        appLanguage == "system" ? .autoupdatingCurrent : Locale(identifier: appLanguage)
    }
}

private struct RootView: View {
    var body: some View {
        TabView {
            NavigationStack { CaptureView() }
                .tabItem { Label { AppText("记录") } icon: { Image(systemName: "waveform.circle.fill") } }
            NavigationStack { PointListView() }
                .tabItem { Label { AppText("想法") } icon: { Image(systemName: "circle.grid.2x2.fill") } }
            NavigationStack { ModelSettingsView() }
                .tabItem { Label { AppText("模型") } icon: { Image(systemName: "cpu") } }
        }
        .tint(.indigo)
    }
}
