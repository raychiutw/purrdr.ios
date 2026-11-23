import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 圖片檢視器(#426)裡的一張圖。
struct ImageViewerSource: Identifiable {
    enum Origin {
        case data(Data)
        case file(URL)
        /// 要用時才取得完整圖(例如經主機取檔);取不到回 `nil`。
        case deferred(@MainActor () async -> Data?)
    }

    let id: Int
    let name: String
    let origin: Origin

    /// 取得圖片位元組;取不到回 `nil`。
    @MainActor
    func data() async -> Data? {
        switch origin {
        case .data(let data): return data
        case .file(let url): return await Task.detached { try? Data(contentsOf: url) }.value
        case .deferred(let load): return await load()
        }
    }
}

/// 要打開的檢視器內容:同一則訊息的圖片清單與起始索引。
struct ImageViewerItem: Identifiable {
    let id = UUID()
    let sources: [ImageViewerSource]
    let startIndex: Int

    init(sources: [ImageViewerSource], startIndex: Int = 0) {
        self.sources = sources
        self.startIndex = startIndex
    }

    /// 單張、已在記憶體裡的圖。
    init(data: Data, name: String) {
        self.init(sources: [ImageViewerSource(id: 0, name: name, origin: .data(data))])
    }
}

extension AgentImageContext {
    /// 完整圖的位元組:已載入就用,否則經主機取檔載入(使用者主動點開,不受自動載入上限限制)。
    @MainActor
    func fullImageData(at path: String) async -> Data? {
        guard let loads else { return nil }
        if case .loaded(let data, _) = loads.states[path] { return data }
        await loads.load(path, scope: scope(), userRequested: true)
        if case .loaded(let data, _) = loads.states[path] { return data }
        return nil
    }
}

/// 共用的全螢幕圖片檢視器(#426,GLOSSARY「圖片檢視器」),使用者送出的圖與 Agent 的圖片卡片都用它。
/// 兩指縮放(1× 到 8×)、雙點兩下放大、放大後單指平移、1× 時往下滑關閉、左右滑看同一則訊息的其他圖片、
/// 頁數「1 / 2」與分享(系統分享表)。縮放規則在 `ImageViewerZoom`,換頁規則在 `ImageViewerPaging`。
/// 左上 ✕ 與 Esc 關閉;VoiceOver 有放大／縮小、上一張／下一張與「Close」動作。
struct ImageViewer: View {
    let item: ImageViewerItem
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var paging: ImageViewerPaging
    @State private var pageDrag: CGFloat = 0
    @State private var isZoomed = false
    /// 1× 時下滑關閉的拖動量(只影響畫面,放開才判斷)。
    @State private var dismissDrag: CGFloat = 0
    /// 各頁讀到後寫進暫存資料夾的檔案(分享用)。
    @State private var shareFiles: [Int: URL] = [:]

    init(item: ImageViewerItem) {
        self.item = item
        let paging = ImageViewerPaging(count: item.sources.count, startIndex: item.startIndex)
        _paging = State(initialValue: paging)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(1 - min(0.5, dismissDrag / 600)).ignoresSafeArea()
            pages
            controls
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("Close")) { dismiss() }
        .accessibilityAction(.escape) { dismiss() }
        .accessibilityIdentifier("imageViewer")
        // 底一律純黑:玻璃按鈕與頁數膠囊固定走深色,淺色模式才不會是黑字疊在灰玻璃上。
        .preferredColorScheme(.dark)
        #if os(iOS)
        .statusBarHidden()
        #endif
    }

    /// 左右換頁:容器自己接橫向拖動(不用 ScrollView,免得和頁面內的縮放、平移手勢互搶);只畫目前與前後各一頁。
    private var pages: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            HStack(spacing: 0) {
                ForEach(item.sources) { source in
                    Group {
                        if abs(source.id - paging.index) <= 1 {
                            ImageViewerPage(
                                source: source, isCurrent: source.id == paging.index, isZoomed: $isZoomed, dismissDrag: $dismissDrag,
                                onClose: { dismiss() },
                                onResolved: { shareFiles[source.id] = Self.shareFile(for: source, data: $0) }
                            )
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: width)
                }
            }
            .offset(x: -CGFloat(paging.index) * width + pageDrag)
            .simultaneousGesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { value in
                        guard !isZoomed, abs(value.translation.width) > abs(value.translation.height) else { return }
                        // 在頭尾再往外拖有阻力。
                        let outward = (value.translation.width > 0 && !paging.canGoPrevious) || (value.translation.width < 0 && !paging.canGoNext)
                        pageDrag = outward ? value.translation.width / 4 : value.translation.width
                    }
                    .onEnded { value in
                        defer { settle { pageDrag = 0 } }
                        guard !isZoomed else { return }
                        let projected = value.predictedEndTranslation.width
                        if (value.translation.width < -width / 4 || projected < -width / 2), paging.canGoNext {
                            settle { paging.goNext() }
                        } else if (value.translation.width > width / 4 || projected > width / 2), paging.canGoPrevious {
                            settle { paging.goPrevious() }
                        }
                    }
            )
        }
        .accessibilityAction(named: Text("Next Image")) { if paging.canGoNext { paging.goNext() } }
        .accessibilityAction(named: Text("Previous Image")) { if paging.canGoPrevious { paging.goPrevious() } }
    }

    private func settle(_ changes: () -> Void) {
        if reduceMotion { changes() } else { withAnimation(.smooth(duration: 0.25), changes) }
    }

    /// 上方一列(設計稿第 30 組):左上 ✕ 關閉(#415)、中間頁數、右上分享;底部分頁點與操作提示。
    /// 觸控目標 44pt:frame 放在 label 裡才撐得大玻璃按鈕(#251)。
    private var controls: some View {
        ZStack {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel(Text("Close"))
                .accessibilityIdentifier("imageViewer.close")
                Spacer()
                if let file = shareFiles[paging.index] {
                    ShareLink(item: file) {
                        Image(systemName: "square.and.arrow.up").frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.glass)
                    .accessibilityLabel(Text("Share"))
                    .accessibilityIdentifier("imageViewer.share")
                } else {
                    Color.clear.frame(width: 44, height: 44)
                }
            }
            .overlay {
                if let label = paging.pageLabel {
                    Text(verbatim: label)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                        .glassEffect(.regular, in: .capsule)
                        .accessibilityLabel(Text("Image \(paging.index + 1) of \(paging.count)"))
                        .accessibilityIdentifier("imageViewer.pageLabel")
                }
            }
            .padding()
            .frame(maxHeight: .infinity, alignment: .top)
            footer
        }
        .opacity(1 - min(1, dismissDrag / 200))
    }

    /// 底部:分頁點(多張才有)與操作提示。
    private var footer: some View {
        VStack(spacing: 14) {
            if item.sources.count > 1 {
                HStack(spacing: 8) {
                    ForEach(item.sources) { source in
                        Circle()
                            .fill(source.id == paging.index ? Color.white : Color.white.opacity(0.3))
                            .frame(width: 8, height: 8)
                    }
                }
                .accessibilityHidden(true)
                .accessibilityIdentifier("imageViewer.dots")
            }
            Text("Double-tap to zoom · swipe down to close")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
                .accessibilityIdentifier("imageViewer.hint")
        }
        .padding(.bottom, 24)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(false)
    }

    /// 分享用的檔案:寫進暫存資料夾、保留檔名(副檔名決定系統怎麼處理)。
    private static func shareFile(for source: ImageViewerSource, data: Data) -> URL? {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ImageViewer-\(UUID().uuidString)")
        let name = source.name.isEmpty ? "Image" : source.name
        let url = folder.appending(path: name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}

/// 檢視器的一頁:載入、解碼、縮放與平移手勢。
private struct ImageViewerPage: View {
    let source: ImageViewerSource
    let isCurrent: Bool
    @Binding var isZoomed: Bool
    @Binding var dismissDrag: CGFloat
    let onClose: () -> Void
    let onResolved: (Data) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: AgentImageDecoder.Decoded?
    @State private var failed = false
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    /// 手勢開始時的值(手勢進行中 `zoom`／`offset` 會跟著變)。
    @State private var pinchStart: (zoom: CGFloat, offset: CGSize)?
    @State private var panStart: CGSize?

    var body: some View {
        Group {
            if let image {
                GeometryReader { proxy in
                    let rules = rules(for: image, in: proxy.size)
                    Image(decorative: image.image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .scaleEffect(zoom)
                        .offset(x: offset.width, y: offset.height + (isCurrent ? dismissDrag : 0))
                        .contentShape(Rectangle())
                        .gesture(pinch(rules))
                        .simultaneousGesture(drag(rules))
                        .gesture(SpatialTapGesture(count: 2).onEnded { event in
                            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
                            let tap = CGPoint(x: event.location.x - center.x, y: event.location.y - center.y)
                            apply(rules.doubleTap(at: tap, zoom: zoom))
                        })
                        .onChange(of: proxy.size) {
                            // 旋轉或改視窗大小:平移夾進新邊界。
                            offset = self.rules(for: image, in: proxy.size).clampedOffset(offset, zoom: zoom)
                        }
                        .accessibilityLabel(Text("Image \(source.name)"))
                        .accessibilityValue(Text(zoom > 1 ? "Zoomed in \(Self.zoomText(zoom))" : "Not zoomed"))
                        .accessibilityAddTraits(.isImage)
                        .accessibilityAction(named: Text("Zoom In")) { zoomTo(max(zoom * 2, ImageViewerZoom.doubleTapZoom), rules) }
                        .accessibilityAction(named: Text("Zoom Out")) { zoomTo(zoom / 2, rules) }
                        .accessibilityIdentifier(isCurrent ? "imageViewer.image" : "imageViewer.otherImage")
                }
            } else if failed {
                Text("This image can't be opened.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("imageViewer.failed")
            } else {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: source.id) {
            guard let data = await source.data() else {
                failed = true
                return
            }
            onResolved(data)
            image = await AgentImageDecoder.decode(data, maxPixels: AgentImageDecoder.fullScreenPixels)
            failed = image == nil
        }
        .onChange(of: zoom) { if isCurrent { isZoomed = zoom > 1.001 } }
        .onChange(of: isCurrent) { if isCurrent { isZoomed = zoom > 1.001 } else { zoom = 1; offset = .zero } }
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
                } else if value.translation.height > 0, value.translation.height > abs(value.translation.width) {
                    // 主要是往下才跟著手指;橫向滑動是換頁,不拖圖。
                    dismissDrag = value.translation.height
                }
            }
            .onEnded { value in
                panStart = nil
                if rules.shouldDismiss(translation: value.translation, zoom: zoom) {
                    onClose()
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
    /// 全螢幕打開圖片檢視器(macOS 只為了 `swift test` 編譯,用 sheet)。
    func imageViewer(item: Binding<ImageViewerItem?>) -> some View {
        #if os(iOS)
        fullScreenCover(item: item) { ImageViewer(item: $0) }
        #else
        sheet(item: item) { ImageViewer(item: $0) }
        #endif
    }
}
