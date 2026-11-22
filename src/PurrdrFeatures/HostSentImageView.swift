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
    /// 點縮圖:交給泡泡打開圖片檢視器(同一則訊息的圖片一起放進去,#426)。
    let open: () -> Void
    @Environment(\.agentImages) private var context
    @State private var thumbnail: AgentImageDecoder.Decoded?
    @State private var thumbnailVersion: HostFileVersion?

    private var state: AgentFileLoads.State? { context.loads?.states[path] }
    private var display: AgentImageCardDisplay { AgentImageCardDisplay(state: state) }
    private var loadedVersion: HostFileVersion? { if case .loaded(_, let version) = state { version } else { nil } }
    private var isLoading: Bool {
        switch state {
        case nil, .loading: true
        default: false
        }
    }

    var body: some View {
        content
            .task(id: path) { await load(userRequested: false) }
            .task(id: loadedVersion) { await decodeThumbnail() }
    }

    @ViewBuilder
    private var content: some View {
        if let thumbnail {
            let size = BubbleImagesView.fitted(CGSize(width: thumbnail.image.width, height: thumbnail.image.height))
            Button(action: open) {
                Image(decorative: thumbnail.image, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.pressableThumbnail(cornerRadius: 14))
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
                .frame(width: BubbleImagesView.longEdge, height: BubbleImagesView.longEdge * 2 / 3)
                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 14))
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
        guard case .loaded(let data, let version) = state, version != thumbnailVersion else { return }
        let decoded = await AgentImageDecoder.decode(data, maxPixels: AgentImageDecoder.thumbnailPixels)
        guard !Task.isCancelled else { return }
        thumbnail = decoded
        thumbnailVersion = decoded == nil ? nil : version
    }
}
