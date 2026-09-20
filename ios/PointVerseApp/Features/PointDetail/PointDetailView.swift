import PointVerseKit
import SwiftUI
import UIKit

struct PointDetailView: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLanguage) private var appLanguage
    @StateObject private var player = AudioPlayerViewModel()
    @State private var detail: PointDetail?
    @State private var images: [LoadedPointImage] = []
    @State private var relatedPoints: [RelatedPoint] = []
    @State private var relatedLoaded = false
    @State private var editedTranscript = ""
    @State private var isEditing = false
    @State private var isSaving = false
    @State private var confirmingDelete = false
    let point: PointSummary

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if detail?.modality != "text" { audioCard }
                transcriptCard
                relatedPointsCard
                ForEach(images) { item in
                    VStack(alignment: .leading, spacing: 10) {
                        Image(uiImage: item.image)
                            .resizable().scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                        if let text = item.asset.recognizedText, !text.isEmpty {
                            Label { Text(verbatim: text).textSelection(.enabled) } icon: {
                                Image(systemName: "text.viewfinder")
                            }
                            .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .background(.background, in: RoundedRectangle(cornerRadius: 20))
                }
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("PointVersePointImagesDidChange"))) { note in
            guard note.object as? String == point.id.rawValue.uuidString else { return }
            Task { await reload() }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if detail?.transcriptState == "failed" {
                        Button { retryTranscription() } label: { Label("重新转写", systemImage: "arrow.clockwise") }
                    }
                    Button(role: .destructive) { confirmingDelete = true } label: { Label("删除", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .confirmationDialog("删除这条想法？", isPresented: $confirmingDelete) {
            Button("删除", role: .destructive) {
                Task { try? await container.deletePoint(point.id); dismiss() }
            }
        } message: { Text("原音、转写和照片都会被永久删除。") }
    }

    private var audioCard: some View {
        HStack(spacing: 14) {
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 44, height: 44).background(.indigo, in: Circle()).foregroundStyle(.white)
            }
            .disabled(!player.isReady)
            VStack(alignment: .leading, spacing: 3) {
                Text("原音已保存").font(.headline)
                if let milliseconds = detail?.durationMilliseconds {
                    Text(duration(milliseconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(16).background(.background, in: RoundedRectangle(cornerRadius: 20))
    }

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(detail?.modality == "text" ? "文本内容" : "系统语音转写",
                  systemImage: detail?.modality == "text" ? "text.alignleft" : "text.quote").font(.headline)
            if let detail {
                if detail.modality == "text" {
                    Text(verbatim: detail.sourceText ?? "").textSelection(.enabled)
                } else { switch detail.transcriptState {
                case "succeeded":
                    if isEditing {
                        TextEditor(text: $editedTranscript).frame(minHeight: 120)
                        Button("保存修正") { saveCorrection() }
                            .buttonStyle(.borderedProminent).disabled(isSaving || editedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else {
                        Text(verbatim: detail.effectiveTranscript ?? "没有识别到文字").textSelection(.enabled)
                        Button("修正文字") { editedTranscript = detail.effectiveTranscript ?? ""; isEditing = true }.font(.footnote)
                    }
                case "running", "queued":
                    HStack { ProgressView(); Text("正在设备端转写") }.foregroundStyle(.secondary)
                case "failed":
                    Text(detail.transcriptErrorCode == PointVerseError.onDeviceRecognitionUnavailable.rawValue
                         ? "当前设备或语言不支持设备端转写，原音仍已保存。" : "转写失败，原音仍已保存。")
                        .foregroundStyle(.secondary)
                    Button("重新转写") { retryTranscription() }
                default: Text("等待转写").foregroundStyle(.secondary)
                }
                }
            } else { ProgressView() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16).background(.background, in: RoundedRectangle(cornerRadius: 20))
    }

    private var relatedPointsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("候选关联", systemImage: "point.3.connected.trianglepath.dotted").font(.headline)
                Spacer()
                Text("E5 多语言").font(.caption2.bold()).foregroundStyle(.mint)
            }
            if !relatedLoaded {
                HStack { ProgressView(); Text("正在分析关联") }.font(.subheadline).foregroundStyle(.secondary)
            } else if relatedPoints.isEmpty {
                Text("暂时没有达到召回阈值的候选内容")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(relatedPoints) { related in
                    NavigationLink {
                        PointDetailView(point: related.point)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Circle().fill(relationColor(related.score)).frame(width: 9, height: 9).padding(.top, 6)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(related.point.title.isEmpty ? "未命名想法" : related.point.title)
                                    .font(.subheadline.bold()).foregroundStyle(.primary).lineLimit(1)
                                Text(related.content).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer(minLength: 8)
                            Text(related.score, format: .number.precision(.fractionLength(3)))
                                .font(.caption.monospacedDigit().bold())
                                .foregroundStyle(relationColor(related.score))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(relationColor(related.score).opacity(0.12), in: Capsule())
                        }
                    }
                    .buttonStyle(.plain)
                    if related.id != relatedPoints.last?.id { Divider() }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16).background(.background, in: RoundedRectangle(cornerRadius: 20))
    }

    private func relationColor(_ score: Float) -> Color {
        score >= 0.94 ? .mint : score >= 0.89 ? .cyan : .indigo
    }

    private var displayTitle: String {
        let value = detail?.title ?? point.title
        return value.isEmpty ? "语音想法" : value
    }

    private func reload() async {
        relatedLoaded = false
        async let related = container.database.relatedPoints(
            to: point.id, modelID: EmbeddingModelIdentity.multilingualE5Small,
            minimumScore: 0.85, limit: 5
        )
        guard let loaded = try? await container.database.pointDetail(id: point.id) else { return }
        detail = loaded
        if let path = loaded.audioRelativePath,
           let url = try? await container.blobStore.url(for: path) { player.prepare(url: url) }
        let assets = (try? await container.database.images(pointID: point.id)) ?? []
        images = await withTaskGroup(of: LoadedPointImage?.self) { group in
            for asset in assets {
                group.addTask {
                    guard let url = try? await container.imageBlobStore.url(for: asset.relativePath),
                          let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { return nil }
                    return LoadedPointImage(asset: asset, image: image)
                }
            }
            var result: [LoadedPointImage] = []
            for await item in group { if let item { result.append(item) } }
            return result.sorted { $0.asset.createdAt < $1.asset.createdAt }
        }
        relatedPoints = (try? await related) ?? []
        relatedLoaded = true
    }

    private func saveCorrection() {
        isSaving = true
        Task {
            try? await container.database.saveUserTranscript(pointID: point.id, userText: editedTranscript)
            container.refreshEmbeddings()
            isSaving = false; isEditing = false; await reload()
        }
    }

    private func retryTranscription() {
        Task {
            await container.transcriptionService.transcribe(pointID: point.id)
            container.refreshEmbeddings()
            await reload()
        }
    }

    private func duration(_ milliseconds: Int) -> String {
        let seconds = milliseconds / 1_000
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct LoadedPointImage: Identifiable {
    var id: UUID { asset.id }
    let asset: PointImage
    let image: UIImage
}
