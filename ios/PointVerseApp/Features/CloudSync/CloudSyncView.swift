import ImageIO
import PointVerseKit
import SwiftUI

struct CloudSyncView: View {
    @EnvironmentObject private var account: AccountSessionStore
    @StateObject private var model: CloudSyncModel
    @State private var location = 0
    @State private var query = ""
    @Environment(\.appLanguage) private var language
    init(library: CloudLocalLibrary) { _model = StateObject(wrappedValue: CloudSyncModel(library: library)) }
    private var visible: [CloudLocalCard] {
        model.items.filter { query.isEmpty || $0.point.title.localizedCaseInsensitiveContains(query) || $0.preview.localizedCaseInsensitiveContains(query) }
    }
    private let columns = [GridItem(.adaptive(minimum: 155), spacing: 12)]
    var body: some View {
        VStack(spacing: 0) {
            Picker("内容位置", selection: $location) {
                AppText("本机").tag(0)
                AppText("云端").tag(1)
            }.pickerStyle(.segmented).padding()
            if model.loading { ProgressView().padding() }
            if let error = model.error { Text(error).font(.footnote).foregroundStyle(.red).padding(.horizontal) }
            if location == 0 {
                if model.items.isEmpty && !model.loading {
                    ContentUnavailableView("还没有想法", systemImage: "square.stack", description: Text("先在本机记录，再选择内容上传。"))
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(visible) { item in
                                Button {
                                    if model.selected.contains(item.id) { model.selected.remove(item.id) }
                                    else { model.selected.insert(item.id) }
                                } label: {
                                    localCard(item)
                                }.buttonStyle(.plain).disabled(model.uploading || item.error != nil)
                            }
                        }.padding(.horizontal).padding(.bottom)
                    }
                }
            } else {
                if model.cloudItems.isEmpty && !model.loading {
                    ContentUnavailableView("云端还没有想法", systemImage: "icloud", description: Text("在本机选择一条或多条想法，上传后会显示在这里。"))
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(model.cloudItems.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.preview.localizedCaseInsensitiveContains(query) }) { version in
                                VStack(alignment: .leading, spacing: 10) {
                                    Image(systemName: version.assetCount > 0 ? "photo.on.rectangle.angled" : "text.alignleft").font(.title).foregroundStyle(.indigo)
                                    Text(version.title.isEmpty ? "未命名想法" : version.title).font(.headline).lineLimit(2)
                                    Text(version.preview).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                                    Spacer(minLength: 0)
                                    Label("已上传", systemImage: "checkmark.icloud").font(.caption).foregroundStyle(.green)
                                    Text(version.uploadedAt, style: .date).font(.caption2).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading).padding(14).background(.background, in: RoundedRectangle(cornerRadius: 16))
                            }
                        }.padding()
                    }
                }
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(AppLocalization.string("云端同步", language: language))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "搜索想法")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if location == 0 {
                    Button(model.selected.isEmpty ? "全选" : "取消选择") {
                        if model.selected.isEmpty { model.selected = Set(visible.filter { $0.error == nil }.map(\.id)) }
                        else { model.selected.removeAll() }
                    }.disabled(model.uploading || model.loading)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                if model.uploading {
                    ProgressView(value: Double(model.completed) + model.progress, total: Double(max(1, model.total)))
                    HStack {
                        Text("正在上传 \(model.completed) / \(model.total)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("暂停上传") { model.pause() }.font(.caption)
                    }
                } else if location == 0 {
                    Button { model.upload(account: account) } label: {
                        Label("上传所选（\(model.selected.count)）", systemImage: "icloud.and.arrow.up").frame(maxWidth: .infinity).padding(.vertical, 7)
                    }.buttonStyle(.borderedProminent).disabled(model.selected.isEmpty || model.loading || account.isSyncing)
                    Text("只上传选中的原文、对话、原音和图片；失败项可再次选择上传。")
                        .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                if location == 1 {
                    Link("在网页查看云端想法", destination: account.registrationURL.appendingPathComponent("library.html")).font(.footnote)
                }
            }.padding().background(.regularMaterial)
        }
        .task { await model.load(account: account) }
        .refreshable { await model.load(account: account) }
        .onDisappear { model.pause() }
        .onReceive(NotificationCenter.default.publisher(for: PointOrganization.didChange)) { _ in Task { await model.load(account: account) } }
    }
    private func localCard(_ item: CloudLocalCard) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .topTrailing) {
                CloudLocalThumbnail(path: item.imagePath, hasAudio: item.hasAudio, model: model)
                Image(systemName: model.selected.contains(item.id) ? "checkmark.circle.fill" : "circle")
                    .font(.title3).symbolRenderingMode(.palette)
                    .foregroundStyle(model.selected.contains(item.id) ? Color.indigo : Color.secondary, Color.white)
                    .padding(8)
            }
            Text(item.point.title.isEmpty ? "未命名想法" : item.point.title).font(.subheadline.bold()).lineLimit(2)
            if !item.preview.isEmpty { Text(item.preview).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
            Text(item.point.createdAt, style: .date).font(.caption2).foregroundStyle(.secondary)
            if let error = model.failures[item.id] ?? item.error { Label(error, systemImage: "exclamationmark.circle").font(.caption2).foregroundStyle(.red).lineLimit(3) }
            else if model.current == item.id { Label("正在上传", systemImage: "arrow.up.circle").font(.caption).foregroundStyle(.indigo) }
            else { Label(model.uploaded(item) ? "已上传" : "待上传", systemImage: model.uploaded(item) ? "checkmark.icloud" : "icloud.and.arrow.up").font(.caption).foregroundStyle(model.uploaded(item) ? .green : .secondary) }
        }.padding(10).frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
            .background(.background, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(model.selected.contains(item.id) ? Color.indigo : .clear, lineWidth: 2))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(model.selected.contains(item.id) ? [.isSelected] : [])
    }
}
private struct CloudLocalThumbnail: View {
    let path: String?
    let hasAudio: Bool
    let model: CloudSyncModel
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(.indigo.opacity(0.06))
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: hasAudio ? "waveform" : "text.alignleft").font(.title).foregroundStyle(.indigo.opacity(0.7)) }
        }.frame(height: 95).clipped().clipShape(RoundedRectangle(cornerRadius: 10))
        .task(id: path) {
            guard let path, let url = await model.imageURL(path), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 320, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return }
            image = UIImage(cgImage: thumbnail)
        }
    }
}
