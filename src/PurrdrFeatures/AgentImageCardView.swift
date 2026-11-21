import CoreGraphics
import Foundation
import ImageIO
import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 圖片卡片(#225)與檔案卡片開啟(#228)的環境:這台主機的載入狀態與聊天的存取範圍。
struct AgentImageContext {
    var loads: AgentFileLoads?
    var scope: @MainActor () -> HostFileAccessScope = { HostFileAccessScope(workingDirectories: [], mentionedPaths: []) }
}

extension EnvironmentValues {
    @Entry var agentImages = AgentImageContext()
}

/// 圖片卡片的顯示文字(#225)。
struct AgentImageCardDisplay {
    let state: AgentFileLoads.State?

    /// 縮圖區顯示的說明;縮圖或載入中時 `nil`。
    var note: String? {
        switch state {
        case .overAutomaticLimit(let size):
            String(localized: "\(Self.size(size)) · Not loaded automatically")
        case .tooLarge(let size):
            String(localized: "Too large to preview here (\(Self.size(size))). Open it on the computer.")
        case .missing: String(localized: "This file is no longer on the computer.")
        case .denied: String(localized: "Purrdr doesn’t open files in this location.")
        case .unsupported: String(localized: "Image previews aren’t available for this computer yet.")
        case .failed: String(localized: "Couldn’t load the image.")
        case .loaded, .loading, nil: nil
        }
    }

    var offersLoad: Bool { if case .overAutomaticLimit = state { true } else { false } }
    var offersRetry: Bool { state == .failed }

    static func size(_ bytes: Int) -> String { Int64(bytes).formatted(.byteCount(style: .file)) }
}

/// 縮圖解碼：在背景以 ImageIO 降採樣，不在主執行緒解完整的大圖。
enum AgentImageDecoder {
    /// 卡片縮圖的長邊(px)。
    static let thumbnailPixels = 1024
    /// 全螢幕檢視的長邊(px)。
    static let fullScreenPixels = 4096

    struct Decoded: @unchecked Sendable {
        let image: CGImage
    }

    static func decode(_ data: Data, maxPixels: Int) async -> Decoded? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels, kCGImageSourceShouldCacheImmediately: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(Decoded.init)
        }.value
    }
}

/// 圖片卡片：Agent 讀過、截取或產生的圖片。標題列同檔案卡片，下方是固定高度的縮圖區(圖到了不改列高);
/// 點縮圖全螢幕看、可縮放。超過 8 MiB 顯示大小與「Load Image」;缺檔、被拒、主機不支援各有說明。
struct AgentImageCardView: View {
    let card: AgentFileCard
    @Environment(\.agentImages) private var context
    @State private var thumbnail: AgentImageDecoder.Decoded?
    @State private var thumbnailVersion: HostFileVersion?
    /// 載入的檔案解不出圖片。
    @State private var decodeFailed = false
    @State private var viewer: AgentImageViewerItem?

    /// 縮圖區的高度(固定，避免圖到了改列高)。
    static let thumbnailHeight: CGFloat = 180

    private var state: AgentFileLoads.State? { context.loads?.states[card.file.path] }
    private var display: AgentFileCardDisplay { AgentFileCardDisplay(file: card.file) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AgentFileCardHeader(card: card, display: display, identifier: "conversation.agentImage.header")
            AgentFileCardDetails(card: card, display: display, identifier: "conversation.agentImage")
            preview
                .frame(maxWidth: .infinity, minHeight: Self.thumbnailHeight, maxHeight: Self.thumbnailHeight)
                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
        .contextMenu {
            Button("Copy Path", systemImage: "document.on.document") { Clipboard.copy(card.file.path) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("Copy Path")) { Clipboard.copy(card.file.path) }
        .accessibilityIdentifier("conversation.agentImage")
        .task(id: card.file.path) { await load(userRequested: false) }
        .task(id: loadedVersion) { await decodeThumbnail() }
        .agentImageViewer(item: $viewer)
    }

    @ViewBuilder
    private var preview: some View {
        let imageDisplay = AgentImageCardDisplay(state: state)
        if let thumbnail {
            Button {
                if case .loaded(let data, _) = state { viewer = AgentImageViewerItem(data: data, name: card.file.name) }
            } label: {
                Image(decorative: thumbnail.image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: Self.thumbnailHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Image \(card.file.name)"))
            .accessibilityHint(Text("Opens the image full screen."))
            .accessibilityIdentifier("conversation.agentImage.thumbnail")
        } else if decodeFailed {
            Text("This file isn’t an image Purrdr can show.")
                .font(.footnote)
                .foregroundStyle(.secondaryText)
                .accessibilityIdentifier("conversation.agentImage.note")
        } else if let note = imageDisplay.note {
            VStack(spacing: 8) {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondaryText)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("conversation.agentImage.note")
                if imageDisplay.offersLoad {
                    // 觸控目標 44pt 撐在 label 上(放在 Button 外只撐大外框，#251)。
                    Button { Task { await load(userRequested: true) } } label: { HitTarget("Load Image") }
                        .accessibilityIdentifier("conversation.agentImage.load")
                }
                if imageDisplay.offersRetry {
                    // 觸控目標 44pt 撐在 label 上(放在 Button 外只撐大外框，#251)。
                    Button { Task { await load(userRequested: false) } } label: { HitTarget("Try Again") }
                        .accessibilityIdentifier("conversation.agentImage.retry")
                }
            }
            .padding(.horizontal, 12)
        } else {
            ProgressView()
                .accessibilityLabel(Text("Loading image"))
                .accessibilityIdentifier("conversation.agentImage.loading")
        }
    }

    private var loadedVersion: HostFileVersion? {
        if case .loaded(_, let version) = state { version } else { nil }
    }

    private func load(userRequested: Bool) async {
        guard let loads = context.loads else { return }
        await loads.load(card.file.path, scope: context.scope(), userRequested: userRequested)
    }

    private func decodeThumbnail() async {
        guard case .loaded(let data, let version) = state, version != thumbnailVersion else { return }
        let decoded = await AgentImageDecoder.decode(data, maxPixels: AgentImageDecoder.thumbnailPixels)
        guard !Task.isCancelled else { return }
        thumbnail = decoded
        thumbnailVersion = decoded == nil ? nil : version
        decodeFailed = decoded == nil
    }
}

/// 全螢幕檢視的圖片。
struct AgentImageViewerItem: Identifiable {
    let id = UUID()
    let data: Data
    let name: String
}

/// 全螢幕檢視(#330,照 HIG 手勢表與「照片」app):兩指縮放(1× 到 8×,放開夾回範圍)、
/// 雙點兩下以點的位置放大或縮回、放大後單指平移(夾在圖邊界內)、1× 時向下滑關閉;
/// 規則在 `ImageViewerZoom`。右上角「Done」與 Esc 關閉;VoiceOver 有放大／縮小與「Close」動作，並念出目前倍率。
struct AgentImageViewer: View {
    let item: AgentImageViewerItem
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: AgentImageDecoder.Decoded?
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    /// 手勢開始時的值(手勢進行中 `zoom`／`offset` 會跟著變)。
    @State private var pinchStart: (zoom: CGFloat, offset: CGSize)?
    @State private var panStart: CGSize?
    /// 1× 時下滑關閉的拖動量(只影響畫面，放開才判斷)。
    @State private var dismissDrag: CGFloat = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(1 - min(0.5, dismissDrag / 600)).ignoresSafeArea()
            if let image {
                GeometryReader { proxy in
                    let rules = rules(for: image, in: proxy.size)
                    Image(decorative: image.image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .scaleEffect(zoom)
                        .offset(x: offset.width, y: offset.height + dismissDrag)
                        .contentShape(Rectangle())
                        .gesture(pinch(rules))
                        .simultaneousGesture(drag(rules))
                        .gesture(SpatialTapGesture(count: 2).onEnded { event in
                            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
                            let tap = CGPoint(x: event.location.x - center.x, y: event.location.y - center.y)
                            apply(rules.doubleTap(at: tap, zoom: zoom))
                        })
                        .onChange(of: proxy.size) {
                            // 旋轉或改視窗大小:倍率夾回範圍、平移夾進新邊界。
                            let next = self.rules(for: image, in: proxy.size)
                            offset = next.clampedOffset(offset, zoom: zoom)
                        }
                        .accessibilityLabel(Text("Image \(item.name)"))
                        .accessibilityValue(Text(zoom > 1 ? "Zoomed in \(Self.zoomText(zoom))" : "Not zoomed"))
                        .accessibilityAddTraits(.isImage)
                        .accessibilityAction(named: Text("Zoom In")) { zoomTo(max(zoom * 2, ImageViewerZoom.doubleTapZoom), rules) }
                        .accessibilityAction(named: Text("Zoom Out")) { zoomTo(zoom / 2, rules) }
                        .accessibilityIdentifier("agentImage.viewer.image")
                }
            } else {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // 觸控目標 44pt:frame 放在 label 裡才撐得大玻璃按鈕(放在外面只撐大外框，按鈕仍是 34pt,#251)。
            Button { dismiss() } label: {
                Text("Done").frame(minWidth: 44, minHeight: 44)
            }
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
                .padding()
                .accessibilityIdentifier("agentImage.viewer.done")
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("Close")) { dismiss() }
        .accessibilityAction(.escape) { dismiss() }
        .accessibilityIdentifier("agentImage.viewer")
        .task { image = await AgentImageDecoder.decode(item.data, maxPixels: AgentImageDecoder.fullScreenPixels) }
        #if os(iOS)
        .statusBarHidden()
        #endif
    }

    /// 圖在 1× 時等比縮進容器的尺寸。
    private func rules(for image: AgentImageDecoder.Decoded, in container: CGSize) -> ImageViewerZoom {
        let size = CGSize(width: image.image.width, height: image.image.height)
        guard size.width > 0, size.height > 0, container.width > 0, container.height > 0 else {
            return ImageViewerZoom(container: container, fitted: container)
        }
        let scale = min(container.width / size.width, container.height / size.height)
        return ImageViewerZoom(container: container, fitted: CGSize(width: size.width * scale, height: size.height * scale))
    }

    private func pinch(_ rules: ImageViewerZoom) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = pinchStart ?? (zoom, offset)
                pinchStart = start
                // 以手指中心為不動點縮放(規則在 ImageViewerZoom.pinched);進行中可略超出範圍,放開時夾回。
                let anchor = CGPoint(
                    x: (value.startAnchor.x - 0.5) * rules.container.width, y: (value.startAnchor.y - 0.5) * rules.container.height)
                let result = rules.pinched(zoom: start.zoom, offset: start.offset, magnification: value.magnification, at: anchor)
                zoom = result.zoom
                offset = result.offset
            }
            .onEnded { _ in
                pinchStart = nil
                settle { zoom = rules.clampedZoom(zoom); offset = rules.clampedOffset(offset, zoom: zoom) }
            }
    }

    private func drag(_ rules: ImageViewerZoom) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if rules.allowsPan(zoom: zoom) {
                    let start = panStart ?? offset
                    panStart = start
                    offset = rules.clampedOffset(
                        CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height), zoom: zoom)
                } else if value.translation.height > 0 {
                    dismissDrag = value.translation.height
                }
            }
            .onEnded { value in
                panStart = nil
                if rules.shouldDismiss(translation: value.translation, zoom: zoom) {
                    dismiss()
                } else {
                    settle { dismissDrag = 0 }
                }
            }
    }

    private func apply(_ result: (zoom: CGFloat, offset: CGSize)) {
        settle { zoom = result.zoom; offset = result.offset }
    }

    /// VoiceOver 的放大／縮小動作:以中心縮放。
    private func zoomTo(_ target: CGFloat, _ rules: ImageViewerZoom) {
        settle { zoom = rules.clampedZoom(target); offset = rules.clampedOffset(offset, zoom: zoom) }
    }

    /// 「減少動態效果」時不做彈簧動畫。
    private func settle(_ changes: () -> Void) {
        if reduceMotion { changes() } else { withAnimation(.smooth(duration: 0.25), changes) }
    }

    private static func zoomText(_ zoom: CGFloat) -> String {
        Double(zoom).formatted(.number.precision(.fractionLength(0...1))) + "×"
    }
}

extension View {
    /// 全螢幕打開圖片卡片的圖(macOS 只為了 `swift test` 編譯，用 sheet)。
    func agentImageViewer(item: Binding<AgentImageViewerItem?>) -> some View {
        #if os(iOS)
        fullScreenCover(item: item) { AgentImageViewer(item: $0) }
        #else
        sheet(item: item) { AgentImageViewer(item: $0) }
        #endif
    }
}
