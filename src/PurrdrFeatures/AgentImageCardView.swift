import CoreGraphics
import Foundation
import ImageIO
import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 圖片卡片的環境(#225):這台主機的載入狀態與聊天的存取範圍。
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
                    Button("Load Image") { Task { await load(userRequested: true) } }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("conversation.agentImage.load")
                }
                if imageDisplay.offersRetry {
                    Button("Try Again") { Task { await load(userRequested: false) } }
                        .frame(minHeight: 44)
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

/// 全螢幕檢視：兩指縮放、拖曳移動、點兩下放大或還原;右上角「Done」關閉。VoiceOver 有「Close」動作與 escape。
struct AgentImageViewer: View {
    let item: AgentImageViewerItem
    @Environment(\.dismiss) private var dismiss
    @State private var image: AgentImageDecoder.Decoded?
    @State private var zoom: CGFloat = 1
    @State private var settledZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var settledOffset: CGSize = .zero

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let image {
                Image(decorative: image.image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(zoom)
                    .offset(offset)
                    .gesture(MagnifyGesture()
                        .onChanged { zoom = max(1, min(8, settledZoom * $0.magnification)) }
                        .onEnded { _ in settledZoom = zoom })
                    .simultaneousGesture(DragGesture()
                        .onChanged { offset = CGSize(width: settledOffset.width + $0.translation.width, height: settledOffset.height + $0.translation.height) }
                        .onEnded { _ in settledOffset = offset })
                    .onTapGesture(count: 2) { toggleZoom() }
                    .accessibilityLabel(Text("Image \(item.name)"))
                    .accessibilityAddTraits(.isImage)
                    .accessibilityAction(named: zoom > 1 ? Text("Zoom Out") : Text("Zoom In")) { toggleZoom() }
                    .accessibilityIdentifier("agentImage.viewer.image")
            } else {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Button("Done") { dismiss() }
                .buttonStyle(.glass)
                .frame(minWidth: 44, minHeight: 44)
                .padding()
                .accessibilityIdentifier("agentImage.viewer.done")
        }
        .accessibilityAction(named: Text("Close")) { dismiss() }
        .accessibilityAction(.escape) { dismiss() }
        .accessibilityIdentifier("agentImage.viewer")
        .task { image = await AgentImageDecoder.decode(item.data, maxPixels: AgentImageDecoder.fullScreenPixels) }
        #if os(iOS)
        .statusBarHidden()
        #endif
    }

    private func toggleZoom() {
        zoom = zoom > 1 ? 1 : 2.5
        settledZoom = zoom
        if zoom == 1 {
            offset = .zero
            settledOffset = .zero
        }
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
