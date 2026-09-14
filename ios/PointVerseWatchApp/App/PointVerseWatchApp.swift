import SwiftUI

@main
struct PointVerseWatchApp: App {
    @StateObject private var model = WatchCaptureViewModel()

    var body: some Scene {
        WindowGroup {
            WatchCaptureView()
                .environmentObject(model)
                .task { await model.prepare() }
        }
    }
}
