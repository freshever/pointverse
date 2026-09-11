import SwiftUI
import UIKit
import PointVerseKit

struct CaptureView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var state: CaptureState = .idle
    @State private var startedAt: Date?
    @State private var elapsed = 0
    @State private var failureKey = "录音启动失败"
    @AppStorage("captureLanguage") private var captureLanguage = ""
    @Environment(\.appLanguage) private var appLanguage

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            AppText(state.title)
                .font(.title2.weight(.semibold))
            if state == .recording {
                Text(String(format: "%02d:%02d", elapsed / 60, elapsed % 60))
                    .foregroundStyle(.secondary)
            } else {
                AppText(state == .failed ? failureKey : state.detail)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Picker(selection: $captureLanguage) {
                AppText("自动").tag("")
                AppText("简体中文").tag("zh-CN")
                AppText("繁体中文").tag("zh-TW")
                AppText("英文").tag("en-US")
                AppText("日文").tag("ja-JP")
            } label: {
                AppText("录音语言")
            }
            .pickerStyle(.menu)
            .disabled(state == .recording || state == .saving)

            Button(action: primaryAction) {
                Image(systemName: state == .recording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 112, height: 112)
                    .background(state == .recording ? Color.red : Color.indigo, in: .circle)
            }
            .accessibilityLabel(AppLocalization.string(state == .recording ? "完成录音" : "开始录音", language: appLanguage))
            .disabled(state == .saving)

            if state == .recording {
                Button(role: .cancel) {
                    Task {
                        await container.captureUseCase.cancel()
                        state = .idle
                    }
                } label: { AppText("取消") }
            }
            if state == .permissionDenied {
                Button {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                } label: {
                    AppText("前往设置")
                }
            }
            Spacer()
        }
        .padding(24)
        .navigationTitle(AppLocalization.string("点界", language: appLanguage))
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
                    let locale = captureLanguage.isEmpty ? Locale.current.identifier : captureLanguage
                    let pointID = try await container.captureUseCase.finish(localeIdentifier: locale)
                    startedAt = nil
                    state = .saved
                    Task { await container.transcriptionService.transcribe(pointID: pointID) }
                } else {
                    elapsed = 0
                    try await container.captureUseCase.start()
                    startedAt = Date()
                    state = .recording
                }
            } catch PointVerseError.microphonePermissionDenied {
                startedAt = nil
                state = .permissionDenied
            } catch let error as PointVerseError {
                startedAt = nil
                failureKey = switch error {
                case .audioSessionUnavailable: "无法启动录音会话"
                case .insufficientDiskSpace: "设备可用空间不足"
                case .audioCommitFailed: "无法保存录音文件"
                case .databaseCommitFailed: "无法保存录音资料"
                default: "录音启动失败"
                }
                state = .failed
            } catch {
                startedAt = nil
                failureKey = "录音启动失败"
                state = .failed
            }
        }
    }
}

private enum CaptureState: Equatable {
    case idle, recording, saving, saved, failed, permissionDenied

    var title: String {
        switch self {
        case .idle: "留下此刻的想法"
        case .recording: "正在录音"
        case .saving: "正在可靠保存"
        case .saved: "原音已保存"
        case .failed: "保存没有完成"
        case .permissionDenied: "需要麦克风权限"
        }
    }

    var detail: String {
        switch self {
        case .idle: "轻点一次开始，再点一次完成"
        case .recording: "正在录音"
        case .saving: "正在写入原音和本地资料库…"
        case .saved: "现在可以退出 App，原音仍会保留"
        case .failed: "录音启动失败"
        case .permissionDenied: "请在系统设置中允许点界访问麦克风"
        }
    }
}
