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
            String(localized: "Too large to preview here (\(Self.size(size))). Open it on the host.")
        case .missing: String(localized: "This file is no longer on the host.")
        case .denied: String(localized: "Purrdr doesn’t open files in this location.")
        case .unsupported: String(localized: "Image previews aren’t available for this host yet.")
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

    /// 解碼後的縮圖;放在 `AgentFileLoads.thumbnails` 共用(#482)。
    typealias Decoded = ThumbnailImage

    /// 快取裡這張圖(目前版本)的縮圖;沒有時 `nil`。列內不自己保存解碼結果。
    @MainActor
    static func cachedThumbnail(path: String, state: AgentFileLoads.State?, maxPixels: Int, in loads: AgentFileLoads?) -> Decoded? {
        guard let loads, case .loaded(_, let version)? = state else { return nil }
        return loads.thumbnails.cachedThumbnail(for: HostImageKey(path: path, version: version, maxPixels: maxPixels))
    }

    /// 載入完成的圖解碼進共用快取(已在快取就不重解碼)並記下尺寸。回 `false` 表示解不出圖;還沒載入完成回 `true`。
    @MainActor
    @discardableResult
    static func decodeIntoCache(path: String, state: AgentFileLoads.State?, kind: AgentFileKind, maxPixels: Int, in loads: AgentFileLoads?) async -> Bool {
        guard let loads, case .loaded(let data, let version)? = state else { return true }
        let key = HostImageKey(path: path, version: version, maxPixels: maxPixels)
        let decoded = await loads.thumbnails.thumbnail(for: key) {
            await decodeThumbnail(data, kind: kind, maxPixels: maxPixels).map { ($0, $0.pixelSize) }
        }
        return decoded != nil
    }

    /// 檔案卡片的縮圖(#427):圖片同 `decode`,PDF 畫第一頁(白底);其他種類沒有縮圖。
    static func decodeThumbnail(_ data: Data, kind: AgentFileKind, maxPixels: Int) async -> Decoded? {
        switch kind {
        case .pdf: await Task.detached(priority: .userInitiated) { renderFirstPage(of: data, maxPixels: maxPixels) }.value
        case .image: await decode(data, maxPixels: maxPixels)
        default: nil
        }
    }

    /// 以 CoreGraphics 畫 PDF 第一頁，長邊 `maxPixels`;加密、空白文件或不是 PDF 回 `nil`。
    private static func renderFirstPage(of data: Data, maxPixels: Int) -> Decoded? {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
              !document.isEncrypted || document.isUnlocked, let page = document.page(at: 1) else { return nil }
        var box = page.getBoxRect(.cropBox)
        if page.rotationAngle % 180 != 0 { box = CGRect(x: 0, y: 0, width: box.height, height: box.width) }
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = CGFloat(maxPixels) / max(box.width, box.height)
        let width = max(1, Int((box.width * scale).rounded())), height = max(1, Int((box.height * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let target = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(target)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: target, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        return context.makeImage().map(Decoded.init)
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
    /// 解碼完成時加一,讓畫面重讀快取(縮圖本身在 `AgentFileLoads.thumbnails`,不放在列內)。
    @State private var decodeRevision = 0
    /// 載入的檔案解不出圖片。
    @State private var decodeFailed = false
    @State private var viewer: ImageViewerItem?

    /// 縮圖區的高度(固定，避免圖到了改列高)。
    static let thumbnailHeight: CGFloat = 180

    private var state: AgentFileLoads.State? { context.loads?.states[card.file.path] }
    private var display: AgentFileCardDisplay { AgentFileCardDisplay(file: card.file) }
    private var thumbnail: AgentImageDecoder.Decoded? {
        _ = decodeRevision
        return AgentImageDecoder.cachedThumbnail(path: card.file.path, state: state, maxPixels: AgentImageDecoder.thumbnailPixels, in: context.loads)
    }

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
        .listContextMenu {
            Button("Copy Path", systemImage: "document.on.document") { Clipboard.copy(card.file.path) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("Copy Path")) { Clipboard.copy(card.file.path) }
        .accessibilityIdentifier("conversation.agentImage")
        .task(id: card.file.path) {
            if let size = card.file.pixelSize { context.loads?.thumbnails.recordTranscriptSize(size, forPath: card.file.path) }
            await load(userRequested: false)
        }
        .task(id: loadedVersion) { await decodeThumbnail() }
        .presentedImageViewer(item: $viewer)
    }

    @ViewBuilder
    private var preview: some View {
        let imageDisplay = AgentImageCardDisplay(state: state)
        if let thumbnail {
            Button {
                if case .loaded(let data, _) = state { viewer = ImageViewerItem(data: data, name: card.file.name) }
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
        await loads.load(card.file.path, scope: context.scope(), userRequested: userRequested, decodesWithImageIO: true)
    }

    private func decodeThumbnail() async {
        let isDecoded = await AgentImageDecoder.decodeIntoCache(
            path: card.file.path, state: state, kind: .image, maxPixels: AgentImageDecoder.thumbnailPixels, in: context.loads
        )
        guard !Task.isCancelled else { return }
        decodeFailed = !isDecoded
        decodeRevision += 1
    }
}
