import SwiftUI
import UIKit

struct SquarePhotoCropView: View {
    let image: UIImage
    let onCancel: () -> Void
    let onConfirm: (Data) -> Void
    @State private var zoom: CGFloat = 1
    @State private var settledZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var settledOffset: CGSize = .zero

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let side = min(proxy.size.width - 32, proxy.size.height - 80)
                let layout = layout(for: side)
                ZStack {
                    Color.black.ignoresSafeArea()
                    ZStack {
                        Image(uiImage: image)
                            .resizable()
                            .frame(width: layout.width, height: layout.height)
                            .offset(clampedOffset(for: layout, side: side))
                    }
                    .frame(width: side, height: side)
                    .clipped()
                    .contentShape(Rectangle())
                    .gesture(dragGesture(layout: layout, side: side))
                    .simultaneousGesture(magnifyGesture(layout: layout, side: side))
                    .overlay {
                        Rectangle().stroke(.white, lineWidth: 2)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(action: onCancel) { AppText("取消") } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            if let data = renderCrop(side: side, layout: layout) { onConfirm(data) }
                        } label: { AppText("使用选取区域") }
                    }
                }
                .navigationTitle(AppLocalization.string("移动和缩放照片", language: appLanguage))
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    @Environment(\.appLanguage) private var appLanguage

    private func layout(for side: CGFloat) -> CGSize {
        let size = image.size
        let base = max(side / max(1, size.width), side / max(1, size.height))
        return CGSize(width: size.width * base * zoom, height: size.height * base * zoom)
    }

    private func clampedOffset(for layout: CGSize, side: CGFloat) -> CGSize {
        CGSize(width: min(max(offset.width, -(layout.width - side) / 2), (layout.width - side) / 2),
               height: min(max(offset.height, -(layout.height - side) / 2), (layout.height - side) / 2))
    }

    private func dragGesture(layout: CGSize, side: CGFloat) -> some Gesture {
        DragGesture().onChanged { value in
            offset = CGSize(width: settledOffset.width + value.translation.width,
                            height: settledOffset.height + value.translation.height)
            offset = clampedOffset(for: layout, side: side)
        }.onEnded { _ in settledOffset = clampedOffset(for: layout, side: side); offset = settledOffset }
    }

    private func magnifyGesture(layout: CGSize, side: CGFloat) -> some Gesture {
        MagnifyGesture().onChanged { value in
            let newZoom = min(6, max(1, settledZoom * value.magnification))
            let ratio = newZoom / settledZoom
            let anchor = CGSize(
                width: (value.startAnchor.x - 0.5) * side,
                height: (value.startAnchor.y - 0.5) * side
            )
            zoom = newZoom
            offset = CGSize(
                width: settledOffset.width * ratio + anchor.width * (1 - ratio),
                height: settledOffset.height * ratio + anchor.height * (1 - ratio)
            )
            offset = clampedOffset(for: self.layout(for: side), side: side)
        }.onEnded { _ in
            settledZoom = zoom
            settledOffset = clampedOffset(for: self.layout(for: side), side: side)
            offset = settledOffset
        }
    }

    private func renderCrop(side: CGFloat, layout: CGSize) -> Data? {
        let finalOffset = clampedOffset(for: layout, side: side)
        let factor = 512 / side
        let drawRect = CGRect(
            x: ((side - layout.width) / 2 + finalOffset.width) * factor,
            y: ((side - layout.height) / 2 + finalOffset.height) * factor,
            width: layout.width * factor,
            height: layout.height * factor
        )
        return autoreleasepool {
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512))
            return renderer.image { _ in image.draw(in: drawRect) }.jpegData(compressionQuality: 0.9)
        }
    }
}
