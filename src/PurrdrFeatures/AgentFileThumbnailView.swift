import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 檔案卡片的縮圖區(#427):PDF(第一頁)與圖片檔在自動載入上限(8 MiB)內自動經主機取檔並縮圖,
/// 依「路徑 + 版本」快取(`AgentFileLoads`,版本沒變只查狀態)。點縮圖以 QuickLook 開啟;
/// 超過 8 MiB 顯示大小與「Load」,超過 25 MiB 或缺檔、被拒、主機不支援顯示原因。內容層，不用玻璃。
struct AgentFileThumbnailView: View {
    let card: AgentFileCard
    /// 點縮圖:下載後以 QuickLook 開啟。
    let open: () -> Void
    @Environment(\.agentImages) private var context
    @State private var thumbnail: AgentImageDecoder.Decoded?
    @State private var thumbnailVersion: HostFileVersion?
    @State private var decodeFailed = false

    private var state: AgentFileLoads.State? { context.loads?.states[card.file.path] }
    private var loadedVersion: HostFileVersion? { if case .loaded(_, let version) = state { version } else { nil } }

    var body: some View {
        slot
            .frame(maxWidth: .infinity, minHeight: AgentImageCardView.thumbnailHeight, maxHeight: AgentImageCardView.thumbnailHeight)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .task(id: card.file.path) { await load(userRequested: false) }
            .task(id: loadedVersion) { await decode() }
    }

    @ViewBuilder
    private var slot: some View {
        let display = AgentFileThumbnailDisplay(state: state)
        if let thumbnail {
            Button(action: open) {
                Image(decorative: thumbnail.image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: AgentImageCardView.thumbnailHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Preview of \(card.file.name)"))
            .accessibilityHint(Text("Downloads the file from the host and shows a preview."))
            .accessibilityIdentifier("conversation.agentFile.thumbnail")
        } else if decodeFailed {
            Image(systemName: AgentFileCardDisplay(file: card.file).symbol)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        } else if let note = display.note {
            VStack(spacing: 8) {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondaryText)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("conversation.agentFile.thumbnailNote")
                if display.offersLoad {
                    Button { Task { await load(userRequested: true) } } label: { HitTarget("Load") }
                        .accessibilityLabel(Text("Load \(card.file.name)"))
                        .accessibilityIdentifier("conversation.agentFile.load")
                }
                if display.offersRetry {
                    Button { Task { await load(userRequested: false) } } label: { HitTarget("Try Again") }
                        .accessibilityIdentifier("conversation.agentFile.thumbnailRetry")
                }
            }
            .padding(.horizontal, 12)
        } else {
            ProgressView()
                .accessibilityLabel(Text("Loading preview"))
                .accessibilityIdentifier("conversation.agentFile.thumbnailLoading")
        }
    }

    private func load(userRequested: Bool) async {
        guard let loads = context.loads else { return }
        await loads.load(card.file.path, scope: context.scope(), userRequested: userRequested)
    }

    private func decode() async {
        guard case .loaded(let data, let version) = state, version != thumbnailVersion else { return }
        let decoded = await AgentImageDecoder.decodeThumbnail(data, kind: card.file.kind, maxPixels: AgentImageDecoder.thumbnailPixels)
        guard !Task.isCancelled else { return }
        thumbnail = decoded
        thumbnailVersion = decoded == nil ? nil : version
        decodeFailed = decoded == nil
    }
}
