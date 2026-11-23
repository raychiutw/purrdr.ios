import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 檔案卡片的縮圖框(#427、#465):46×56,PDF(第一頁)與圖片檔在自動載入上限(8 MiB)內自動經主機取檔並縮圖,
/// 依「路徑 + 版本」快取(`AgentFileLoads`,版本沒變只查狀態);沒有縮圖時顯示副檔名角標(沒有副檔名用類型圖示)。
/// 載入、取消與錯誤說明在卡片列的副標與右側動作(`AgentFileRowDisplay`)。內容層，不用玻璃。
struct AgentFileThumbnailView: View {
    let card: AgentFileCard
    /// 縮圖框的大小(設計稿第 30 組)。
    static let size = CGSize(width: 46, height: 56)
    @Environment(\.agentImages) private var context
    /// 解碼完成時加一,讓畫面重讀共用快取(縮圖不放在列內,#482)。
    @State private var decodeRevision = 0

    private var display: AgentFileCardDisplay { AgentFileCardDisplay(file: card.file) }
    private var state: AgentFileLoads.State? { context.loads?.states[card.file.path] }
    private var loadedVersion: HostFileVersion? { if case .loaded(_, let version) = state { version } else { nil } }
    private var thumbnail: AgentImageDecoder.Decoded? {
        _ = decodeRevision
        return AgentImageDecoder.cachedThumbnail(path: card.file.path, state: state, maxPixels: Self.thumbnailPixels, in: context.loads)
    }
    /// 縮圖長邊(px);與圖片卡片不同,另成一個快取項目。
    static let thumbnailPixels = 192

    var body: some View {
        frame
            .frame(width: Self.size.width, height: Self.size.height)
            .accessibilityHidden(true)
            .accessibilityIdentifier("conversation.agentFile.thumbnail")
            .task(id: card.file.path) {
                guard display.preview == .thumbnail, let loads = context.loads else { return }
                await loads.load(card.file.path, scope: context.scope(), userRequested: false)
            }
            .task(id: loadedVersion) { await decode() }
    }

    @ViewBuilder
    private var frame: some View {
        if let thumbnail {
            Image(decorative: thumbnail.image, scale: 1)
                .resizable()
                .scaledToFill()
                .frame(width: Self.size.width, height: Self.size.height)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.separator) }
        } else {
            let badge = AgentFileRowDisplay(file: card.file, thumbnail: nil, open: nil).badge
            RoundedRectangle(cornerRadius: 8)
                .fill(.fill.quaternary)
                .overlay {
                    if badge.isEmpty {
                        Image(systemName: display.symbol)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(verbatim: badge)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondaryText)
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)
                            .padding(.horizontal, 2)
                    }
                }
        }
    }

    private func decode() async {
        await AgentImageDecoder.decodeIntoCache(
            path: card.file.path, state: state, kind: card.file.kind, maxPixels: Self.thumbnailPixels, in: context.loads
        )
        guard !Task.isCancelled else { return }
        decodeRevision += 1
    }
}
