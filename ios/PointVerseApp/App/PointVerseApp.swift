import SwiftUI

@main
struct PointVerseApp: App {
    @StateObject private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(container)
                .task { await container.prepare() }
        }
    }
}

private struct RootView: View {
    var body: some View {
        TabView {
            NavigationStack { CaptureView() }
                .tabItem { Label("记录", systemImage: "waveform.circle.fill") }
            NavigationStack { PointListView() }
                .tabItem { Label("想法", systemImage: "circle.grid.2x2.fill") }
            NavigationStack { ModelSettingsView() }
                .tabItem { Label("模型", systemImage: "cpu") }
        }
        .tint(.indigo)
    }
}
