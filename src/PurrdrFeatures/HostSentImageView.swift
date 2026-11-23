import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 使用者送出、手機上沒有副本的圖片(#428):經主機取檔從上傳資料夾讀回縮圖。規則與快取同 Agent 圖片卡片
/// (自動載入 8 MiB、版本沒變只查狀態);超過上限顯示大小等點擊,被主機清掉顯示「主機上已找不到」,
/// 主機服務太舊(0.13.0 之前，`HostServiceFeature.userUploadFetch`)或讀不到時退回「Image」字樣、不顯示錯誤說明。縮圖點開是共用的圖片檢視器。
struct HostSentImageView: View {
    let path: String
    /// 這是同一則訊息的第幾張(VoiceOver 念「Image N」)。
    let index: Int
    /// 單張依比例、多張方塊格子(#465)。
    var layout = BubbleImageLayout(count: 1)
    /// 點縮圖:交給泡泡打開圖片檢視器(同一則訊息的圖片一起放進去,#426)。
    let open: () -> Void
    @Environment(\.agentImages) private var context
    /// 解碼完成時加一,讓畫面重讀快取(縮圖與尺寸在 `AgentFileLoads.thumbnails`,不放在列內)。
    @State private var decodeRevision = 0
    @State private var decodeFailed = false

    private var state: AgentFileLoads.State? { context.loads?.states[path] }
    private var display: AgentImageCardDisplay { AgentImageCardDisplay(state: state) }
    private var loadedVersion: HostFileVersion? { if case .loaded(_, let version) = state { version } else { nil } }
    private var thumbnail: AgentImageDecoder.Decoded? {
        _ = decodeRevision
        return AgentImageDecoder.cachedThumbnail(path: path, state: state, maxPixels: AgentImageDecoder.thumbnailPixels, in: context.loads)
    }
    /// 還在載入或等解碼(被淘汰後重新解碼)時用佔位,不退回一行字。
    private var isLoading: Bool {
        switch state {
        case nil, .loading: true
        case .loaded: !decodeFailed
        default: false
        }
    }
    /// 佔位的大小:尺寸已知(解碼過或對話紀錄帶的)就用最終高度,否則固定比例。
    private var placeholderSize: CGSize {
        if layout.isGrid { return CGSize(width: BubbleImageLayout.tile, height: BubbleImageLayout.tile) }
        if let known = context.loads?.thumbnails.size(forPath: path, version: loadedVersion) {
            return layout.size(forImage: CGSize(width: known.width, height: known.height))
        }
        return CGSize(width: BubbleImageLayout.longEdge, height: BubbleImageLayout.longEdge * 2 / 3)
    }

    var body: some View {
        content
            .task(id: path) { await load(userRequested: false) }
            .task(id: loadedVersion) { await decodeThumbnail() }
    }

    @ViewBuilder
    private var content: some View {
        if let thumbnail {
            let size = layout.size(forImage: CGSize(width: thumbnail.image.width, height: thumbnail.image.height))
            Button(action: open) {
                Image(decorative: thumbnail.image, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: BubbleImageLayout.cornerRadius))
            }
            .buttonStyle(.pressableThumbnail(cornerRadius: BubbleImageLayout.cornerRadius))
            .accessibilityLabel(Text("Image \(index + 1)"))
            .accessibilityHint(Text("Opens the image full screen."))
            .accessibilityIdentifier("conversation.sentImage.thumbnail")
        } else if let note = display.note, state != .unsupported {
            VStack(alignment: .trailing, spacing: 4) {
                Label("Image", systemImage: "photo")
                    .font(.caption)
                    .foregroundStyle(.secondaryText)
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondaryText)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("conversation.sentImage.note")
                if display.offersLoad {
                    Button { Task { await load(userRequested: true) } } label: { HitTarget("Load Image") }
                        .accessibilityIdentifier("conversation.sentImage.load")
                }
            }
            .accessibilityElement(children: .contain)
        } else if isLoading {
            ProgressView()
                .frame(width: placeholderSize.width, height: placeholderSize.height)
                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: BubbleImageLayout.cornerRadius))
                .accessibilityLabel(Text("Loading image"))
                .accessibilityIdentifier("conversation.sentImage.loading")
        } else {
            Label("Image", systemImage: "photo")
                .font(.caption)
                .foregroundStyle(.secondaryText)
                .accessibilityLabel(Text("Image on the host"))
        }
    }

    private func load(userRequested: Bool) async {
        guard let loads = context.loads else { return }
        await loads.load(path, scope: context.scope(), userRequested: userRequested)
    }

    private func decodeThumbnail() async {
        let isDecoded = await AgentImageDecoder.decodeIntoCache(
            path: path, state: state, kind: .image, maxPixels: AgentImageDecoder.thumbnailPixels, in: context.loads
        )
        guard !Task.isCancelled else { return }
        decodeFailed = !isDecoded
        decodeRevision += 1
    }
}
