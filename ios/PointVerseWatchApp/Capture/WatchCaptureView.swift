import SwiftUI
import WatchKit

struct WatchCaptureView: View {
    @EnvironmentObject private var model: WatchCaptureViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    Text(model.statusText)
                        .font(.headline)
                        .multilineTextAlignment(.center)

                    Image(systemName: model.isRecording ? "stop.fill" : "viewfinder")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 82, height: 82)
                        .background(model.isRecording ? Color.red : Color.indigo)
                        .clipShape(Circle())
                        .scaleEffect(model.isPressed ? 1.08 : 1)
                        .contentShape(Circle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { _ in model.pressBegan() }
                                .onEnded { _ in model.pressEnded() }
                        )
                        .accessibilityLabel(model.isRecording ? "松开保存" : "按住录音")

                    Text(model.isRecording ? model.elapsedText : "按住录音，松开保存")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()

                    if let error = model.errorMessage {
                        Text(error).font(.caption2).foregroundStyle(.red)
                    }

                    if !model.captures.isEmpty {
                        Divider()
                        ForEach(model.captures.prefix(5)) { capture in
                            HStack {
                                Image(systemName: capture.syncState == .acknowledged ? "checkmark.icloud" : "icloud.and.arrow.up")
                                VStack(alignment: .leading) {
                                    Text(capture.capturedAt, style: .time)
                                    Text(capture.syncState.displayName).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
            }
            .navigationTitle("点界")
        }
    }
}
