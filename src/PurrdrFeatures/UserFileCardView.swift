import PurrdrAgentFeatures
import PurrdrCore
import QuickLook
import SwiftUI

/// 使用者送出的檔案卡片(#429)的顯示規則:縮圖(PDF、圖片)或類型圖示、檔名、大小;找不到、超過上限說明原因。
/// 主機服務太舊(`unsupported`)或讀不到時只顯示檔名,不顯示錯誤說明。
struct UserFileCardDisplay {
    let path: String
    /// 縮圖種類(PDF、圖片)用 `AgentFileLoads.states`;其他種類只查狀態用 `infos`。
    let state: AgentFileLoads.State?
    let info: AgentFileLoads.Info?
    let open: AgentFileLoads.OpenState?

    private var file: AgentFileReference { AgentFileReference(origin: .created, path: path) }
    var name: String { file.name }
    var symbol: String { AgentFileCardDisplay(file: file).symbol }
    /// 要不要自動載入縮圖:PDF 與圖片(8 MiB 內,#427 的規則)。
    var wantsThumbnail: Bool { AgentFileCardDisplay(file: file).preview == .thumbnail }

    /// 大小(已知時)。
    var size: Int? {
        if wantsThumbnail {
            switch state {
            case .loaded(let data, _): return data.count
            case .overAutomaticLimit(let size), .tooLarge(let size): return size
            default: return nil
            }
        }
        switch info {
        case .available(let size), .tooLarge(let size): return size
        default: return nil
        }
    }

    var sizeText: String? { size.map { Int64($0).formatted(.byteCount(style: .file)) } }

    private var isMissing: Bool { wantsThumbnail ? state == .missing : info == .missing }
    private var isTooLarge: Bool {
        if wantsThumbnail, case .tooLarge = state { return true }
        if case .tooLarge = info { return true }
        if case .tooLarge = open { return true }
        return false
    }

    /// 卡片上的說明:主機上找不到、超過 25 MiB 無法在 app 內開啟;其他情況 `nil`。
    var note: String? {
        if isMissing || open == .missing { return String(localized: "This file is no longer on the host.") }
        if isTooLarge { return String(localized: "Too large to open here. Open it on the host.") }
        return nil
    }

    /// 能不能點開(缺檔或超過上限時不能)。
    var canOpen: Bool { note == nil && !isDownloading }
    var isDownloading: Bool { if case .downloading = open { true } else { false } }
    var progress: Double? {
        guard case .downloading(let received, let total) = open, total > 0 else { return nil }
        return Double(received) / Double(total)
    }

    var accessibilityLabel: String {
        var parts = [String(localized: "Your file \(name)")]
        if let sizeText { parts.append(sizeText) }
        if let note { parts.append(note) }
        return parts.joined(separator: ", ")
    }
}

/// 使用者泡泡裡的縮小檔案卡片(#429):經主機取檔,點擊以 QuickLook 開啟(`HostFileDownloader`,上限 25 MiB)。內容層,不用玻璃。
struct UserFileCardView: View {
    let path: String
    @Environment(\.agentImages) private var context
    /// 解碼完成時加一,讓畫面重讀共用快取(縮圖不放在列內,#482)。
    @State private var decodeRevision = 0
    @State private var previewFile: URL?

    private var display: UserFileCardDisplay {
        UserFileCardDisplay(path: path, state: context.loads?.states[path], info: context.loads?.infos[path], open: context.loads?.opens[path])
    }
    private var thumbnail: AgentImageDecoder.Decoded? {
        _ = decodeRevision
        return AgentImageDecoder.cachedThumbnail(path: path, state: context.loads?.states[path], maxPixels: Self.thumbnailPixels, in: context.loads)
    }
    /// 縮圖長邊(px)。
    static let thumbnailPixels = 160

    private var loadedVersion: HostFileVersion? { if case .loaded(_, let version) = context.loads?.states[path] { version } else { nil } }

    var body: some View {
        let display = display
        HStack(spacing: 6) {
            Button { open() } label: {
                HStack(spacing: 10) {
                    icon(display)
                        .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: display.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let note = display.note {
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(.secondaryText)
                                .accessibilityIdentifier("conversation.userFile.note")
                        } else if let sizeText = display.sizeText {
                            Text(sizeText)
                                .font(.caption)
                                .foregroundStyle(.secondaryText)
                                .accessibilityIdentifier("conversation.userFile.size")
                        }
                    }
                    if display.isDownloading {
                        Group {
                            if let progress = display.progress { ProgressView(value: progress) } else { ProgressView() }
                        }
                        .frame(maxWidth: 44)
                        .accessibilityLabel(Text("Downloading \(display.name)"))
                    }
                }
                .padding(8)
                .frame(minHeight: 44)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
                .contentShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(!display.canOpen)
            .accessibilityLabel(Text(display.accessibilityLabel))
            .accessibilityHint(Text("Downloads the file from the host and shows a preview."))
            .accessibilityIdentifier("conversation.userFile")
            if display.isDownloading {
                Button("Cancel") { context.loads?.cancelOpen(path) }
                    .font(.footnote)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("conversation.userFile.cancel")
            }
        }
        .frame(maxWidth: 300, alignment: .trailing)
        .presentedQuickLook($previewFile)
        .task(id: path) { await refresh() }
        .task(id: loadedVersion) { await decode() }
    }

    @ViewBuilder
    private func icon(_ display: UserFileCardDisplay) -> some View {
        if let thumbnail {
            Image(decorative: thumbnail.image, scale: 1)
                .resizable()
                .scaledToFill()
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            Image(systemName: display.symbol)
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    private func refresh() async {
        guard let loads = context.loads else { return }
        if display.wantsThumbnail {
            await loads.load(path, scope: context.scope(), userRequested: false)
        } else {
            await loads.inspect(path, scope: context.scope())
        }
    }

    private func decode() async {
        let kind = AgentFileReference(origin: .created, path: path).kind
        await AgentImageDecoder.decodeIntoCache(path: path, state: context.loads?.states[path], kind: kind, maxPixels: Self.thumbnailPixels, in: context.loads)
        guard !Task.isCancelled else { return }
        decodeRevision += 1
    }

    /// 下載(版本沒變只查狀態)後以 QuickLook 開。
    private func open() {
        guard let loads = context.loads, display.canOpen else { return }
        let scope = context.scope()
        Task { if let file = await loads.open(path, scope: scope) { previewFile = file } }
    }
}
