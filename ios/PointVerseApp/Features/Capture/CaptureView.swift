import SwiftUI
import UIKit
import PointVerseKit

struct CaptureView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var state: CaptureState = .idle
    @State private var startedAt: Date?
    @State private var elapsed = 0
    @State private var failureKey = "录音启动失败"
    @State private var isPressingRecord = false
    @State private var recordingStartTask: Task<Void, Never>?
    @State private var activeLocaleIdentifier: String?
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

            ZStack {
                Circle()
                    .fill(state == .recording ? Color.red : Color.indigo)
                Image(systemName: state == .recording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 112, height: 112)
            .scaleEffect(isPressingRecord ? 1.08 : 1)
            .animation(.easeOut(duration: 0.12), value: isPressingRecord)
            .contentShape(Circle())
            .onLongPressGesture(
                minimumDuration: 0.22,
                maximumDistance: 80,
                pressing: handlePressing,
                perform: beginRecording
            )
            .accessibilityLabel(AppLocalization.string(state == .recording ? "完成录音" : "开始录音", language: appLanguage))
            .accessibilityHint(AppLocalization.string("按住录音，松开结束", language: appLanguage))
            .disabled(state == .saving)

            if state == .recording {
                Button(role: .cancel) {
                    Task {
                        await container.captureUseCase.cancel()
                        activeLocaleIdentifier = nil
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

    private func handlePressing(_ pressing: Bool) {
        isPressingRecord = pressing
        if !pressing, state == .recording {
            finishRecording()
        }
    }

    private func beginRecording() {
        guard state == .idle || state == .saved || state == .failed else { return }
        let localeIdentifier = resolvedCaptureLocaleIdentifier
        activeLocaleIdentifier = localeIdentifier
        PointVerseLog.capture.info("Recording language locked: \(localeIdentifier, privacy: .public)")
        recordingStartTask = Task {
            do {
                elapsed = 0
                try await container.captureUseCase.start()
                startedAt = Date()
                state = .recording
                if !isPressingRecord {
                    finishRecording()
                }
            } catch PointVerseError.microphonePermissionDenied {
                startedAt = nil
                activeLocaleIdentifier = nil
                state = .permissionDenied
            } catch let error as PointVerseError {
                startedAt = nil
                activeLocaleIdentifier = nil
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
                activeLocaleIdentifier = nil
                failureKey = "录音启动失败"
                state = .failed
            }
        }
    }

    private func finishRecording() {
        guard state == .recording else { return }
        state = .saving
        Task {
            do {
                let localeIdentifier = activeLocaleIdentifier ?? resolvedCaptureLocaleIdentifier
                let pointID = try await container.captureUseCase.finish(localeIdentifier: localeIdentifier)
                startedAt = nil
                activeLocaleIdentifier = nil
                state = .saved
                Task { await container.transcriptionService.transcribe(pointID: pointID) }
            } catch let error as PointVerseError {
                startedAt = nil
                activeLocaleIdentifier = nil
                failureKey = switch error {
                case .insufficientDiskSpace: "设备可用空间不足"
                case .audioCommitFailed: "无法保存录音文件"
                case .databaseCommitFailed: "无法保存录音资料"
                default: "录音启动失败"
                }
                state = .failed
            } catch {
                startedAt = nil
                activeLocaleIdentifier = nil
                failureKey = "录音启动失败"
                state = .failed
            }
        }
    }

    private var resolvedCaptureLocaleIdentifier: String {
        if !captureLanguage.isEmpty { return captureLanguage }
        if appLanguage != "system", !appLanguage.isEmpty {
            switch appLanguage {
            case "zh-Hans": return "zh-CN"
            case "zh-Hant": return "zh-TW"
            case "ja": return "ja-JP"
            case "en": return "en-US"
            default: break
            }
        }
        return Locale.current.identifier
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
        case .idle: "按住录音，松开结束"
        case .recording: "松开即可结束"
        case .saving: "正在写入原音和本地资料库…"
        case .saved: "现在可以退出 App，原音仍会保留"
        case .failed: "录音启动失败"
        case .permissionDenied: "请在系统设置中允许点界访问麦克风"
        }
    }
}
