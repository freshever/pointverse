import SwiftUI

struct CaptureView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var state: CaptureState = .idle
    @State private var startedAt: Date?
    @State private var elapsed = 0

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Text(state.title)
                .font(.title2.weight(.semibold))
            Text(state.detail(elapsed: elapsed))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button(action: primaryAction) {
                Image(systemName: state == .recording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 112, height: 112)
                    .background(state == .recording ? Color.red : Color.indigo, in: .circle)
            }
            .accessibilityLabel(state == .recording ? "完成录音" : "开始录音")
            .disabled(state == .saving)

            if state == .recording {
                Button("取消", role: .cancel) {
                    Task {
                        await container.captureUseCase.cancel()
                        state = .idle
                    }
                }
            }
            Spacer()
        }
        .padding(24)
        .navigationTitle("点界")
        .task(id: startedAt) {
            guard let startedAt else { return }
            while !Task.isCancelled {
                elapsed = Int(Date().timeIntervalSince(startedAt))
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func primaryAction() {
        Task {
            do {
                if state == .recording {
                    state = .saving
                    let pointID = try await container.captureUseCase.finish()
                    startedAt = nil
                    state = .saved
                    Task { await container.transcriptionService.transcribe(pointID: pointID) }
                } else {
                    elapsed = 0
                    try await container.captureUseCase.start()
                    startedAt = Date()
                    state = .recording
                }
            } catch {
                startedAt = nil
                state = .failed
            }
        }
    }
}

private enum CaptureState: Equatable {
    case idle, recording, saving, saved, failed

    var title: String {
        switch self {
        case .idle: "留下此刻的想法"
        case .recording: "正在录音"
        case .saving: "正在可靠保存"
        case .saved: "原音已保存"
        case .failed: "保存没有完成"
        }
    }

    func detail(elapsed: Int) -> String {
        switch self {
        case .idle: "轻点一次开始，再点一次完成"
        case .recording: String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
        case .saving: "正在写入原音和本地资料库…"
        case .saved: "现在可以退出 App，原音仍会保留"
        case .failed: "请检查麦克风权限或可用空间后重试"
        }
    }
}
