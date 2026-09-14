import Combine
import Foundation
import WatchKit

@MainActor
final class WatchCaptureViewModel: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isPressed = false
    @Published private(set) var captures: [WatchCaptureManifest] = []
    @Published private(set) var elapsedText = "00:00"
    @Published var errorMessage: String?

    private let recorder = WatchAudioRecorder()
    private let store = WatchCaptureStore()
    private let transfer = WatchTransferManager.shared
    private var pressTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var fingerIsDown = false

    var statusText: String {
        if isRecording { return "正在录音" }
        if captures.first?.syncState == .acknowledged { return "已保存到 iPhone" }
        if !captures.isEmpty { return "已保存到手表" }
        return "记录此刻的想法"
    }

    func prepare() async {
        transfer.activate()
        captures = (try? await store.allCaptures()) ?? []
        await queuePendingTransfers()
    }

    func pressBegan() {
        guard !fingerIsDown else { return }
        fingerIsDown = true
        isPressed = true
        errorMessage = nil
        pressTask = Task {
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled, fingerIsDown else { return }
            await startRecording()
        }
    }

    func pressEnded() {
        fingerIsDown = false
        isPressed = false
        pressTask?.cancel()
        pressTask = nil
        if isRecording { Task { await finishRecording() } }
    }

    private func startRecording() async {
        do {
            let captureID = UUID()
            let url = try await store.stagingURL(captureID: captureID)
            try await recorder.start(captureID: captureID, url: url)
            isRecording = true
            WKInterfaceDevice.current().play(.start)
            timerTask = Task {
                var seconds = 0
                while !Task.isCancelled {
                    elapsedText = await recorder.elapsedText()
                    try? await Task.sleep(for: .seconds(1))
                    seconds += 1
                    if seconds >= 60 {
                        fingerIsDown = false
                        isPressed = false
                        await finishRecording()
                        return
                    }
                }
            }
        } catch {
            errorMessage = "无法开始录音，请检查麦克风权限"
            fingerIsDown = false
            isPressed = false
        }
    }

    private func finishRecording() async {
        timerTask?.cancel()
        timerTask = nil
        isRecording = false
        elapsedText = "00:00"
        do {
            let result = try await recorder.stop()
            var manifest = try await store.commit(result)
            manifest.syncState = .queued
            try await store.update(manifest)
            captures = try await store.allCaptures()
            transfer.enqueue(fileURL: try await store.audioURL(for: manifest), manifest: manifest)
            WKInterfaceDevice.current().play(.success)
        } catch {
            errorMessage = "录音未能保存"
            WKInterfaceDevice.current().play(.failure)
        }
    }

    private func queuePendingTransfers() async {
        for capture in captures where capture.syncState != .acknowledged {
            if let url = try? await store.audioURL(for: capture) {
                transfer.enqueue(fileURL: url, manifest: capture)
            }
        }
    }
}
