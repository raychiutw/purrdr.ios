import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// 檔案卡片的顯示規則(#224)。
struct AgentFileCardDisplay {
    /// 內容的一行。修改摘要的行帶種類，畫面依此選顏色;符號(`+`／`-`)留在文字裡，不只靠顏色。
    struct Line: Equatable {
        enum Kind: Equatable { case plain, added, removed, context, hunkHeader }
        var text: String
        var kind: Kind
    }

    let file: AgentFileReference

    /// 「Created」「Overwritten」「Edited」;圖片是「Read」「Captured」(工具結果帶圖)「Generated」。
    var originText: String {
        switch file.origin {
        case .created: String(localized: "Created")
        case .overwritten: String(localized: "Overwritten")
        case .edited: String(localized: "Edited")
        case .readImage: String(localized: "Read")
        case .toolImage: String(localized: "Captured")
        case .generatedImage: String(localized: "Generated")
        }
    }

    var kindText: String {
        switch file.kind {
        case .text: String(localized: "Text")
        case .markdown: String(localized: "Markdown")
        case .code: String(localized: "Code")
        case .image: String(localized: "Image")
        case .pdf: String(localized: "PDF")
        case .data: String(localized: "Data")
        case .other: String(localized: "File")
        }
    }

    /// 卡片上方的預覽(#427):PDF 與圖片自動縮圖;文字、程式碼等有對話紀錄內容的沿用內容摘要;其他顯示類型圖示。
    enum Preview: Equatable { case thumbnail, snapshot, typeIcon }

    var preview: Preview {
        switch file.kind {
        case .pdf, .image: .thumbnail
        default: file.snapshot == nil ? .typeIcon : .snapshot
        }
    }

    var symbol: String {
        switch file.kind {
        case .text, .markdown: "doc.text"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .data: "tablecells"
        case .other: Self.typeSymbol(forExtension: file.fileExtension)
        }
    }

    /// 其他種類依系統的檔案類型(UTType)挑圖示。
    private static func typeSymbol(forExtension fileExtension: String) -> String {
        guard let type = UTType(filenameExtension: fileExtension) else { return "doc" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return "film" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .spreadsheet) { return "tablecells" }
        if type.conforms(to: .presentation) { return "rectangle.on.rectangle" }
        return "doc"
    }

    /// 「Created · Code · 312 bytes」、「Edited · Code · +1 −1」。
    var summary: String {
        var parts = [originText, kindText]
        if let byteCount = file.byteCount { parts.append(Int64(byteCount).formatted(.byteCount(style: .file))) }
        if case .edit(let change) = file.snapshot { parts.append("+\(change.addedLines) −\(change.removedLines)") }
        return parts.joined(separator: " · ")
    }

    /// VoiceOver 念的標題：動作、檔名、類型、大小或增刪行數。路徑是進階資訊(#330)，在揭露控制裡。
    var accessibilityLabel: String {
        var parts = [String(localized: "\(originText) file \(file.name)"), kindText]
        if let byteCount = file.byteCount { parts.append(Int64(byteCount).formatted(.byteCount(style: .file))) }
        if case .edit(let change) = file.snapshot {
            parts.append(String(localized: "\(change.addedLines) lines added, \(change.removedLines) removed"))
        }
        return parts.joined(separator: ", ")
    }

    var lines: [Line] {
        switch file.snapshot {
        case .content(let text, _):
            return text.isEmpty ? [] : text.split(separator: "\n", omittingEmptySubsequences: false).map { Line(text: String($0), kind: .plain) }
        case .edit(let change):
            return change.hunks.flatMap { hunk in
                [Line(text: "@@ -\(hunk.oldStart),\(hunk.oldLines) +\(hunk.newStart),\(hunk.newLines) @@", kind: .hunkHeader)]
                    + hunk.lines.map { line in
                        Line(text: line, kind: line.hasPrefix("+") ? .added : line.hasPrefix("-") ? .removed : .context)
                    }
            }
        case nil:
            return []
        }
    }

    var truncationNote: String? {
        switch file.snapshot {
        case .content(_, isTruncated: true): String(localized: "Content truncated at 20,000 characters")
        case .edit(let change) where change.isTruncated: String(localized: "Changes truncated at 20,000 characters")
        default: nil
        }
    }

    /// 長按「複製內容」:寫入的內容或修改摘要。沒有內容時 `nil`。
    var copyableContent: String? {
        let text = lines.map(\.text).joined(separator: "\n")
        return text.isEmpty ? nil : text
    }
}

/// 檔案卡片縮圖區(#427)的說明:超過 8 MiB 顯示大小與「載入」、超過 25 MiB 無法開啟、缺檔、被拒、主機不支援。
struct AgentFileThumbnailDisplay {
    let state: AgentFileLoads.State?

    /// 縮圖區顯示的說明;縮圖或載入中時 `nil`。
    var note: String? {
        switch state {
        case .overAutomaticLimit(let size): String(localized: "\(AgentImageCardDisplay.size(size)) · Not loaded automatically")
        case .tooLarge(let size):
            String(localized: "Too large to open here (\(AgentImageCardDisplay.size(size))). Open it on the host.")
        case .missing: String(localized: "This file is no longer on the host.")
        case .denied: String(localized: "Purrdr doesn’t open files in this location.")
        case .unsupported: String(localized: "Opening files isn’t available for this host yet.")
        case .failed: String(localized: "Couldn’t download the file.")
        case .loaded, .loading, nil: nil
        }
    }

    var offersLoad: Bool { if case .overAutomaticLimit = state { true } else { false } }
    var offersRetry: Bool { state == .failed }
}

/// 檔案卡片緊湊單列(#465,設計稿第 30 組)的顯示規則:副標、右側動作、進度與縮圖框角標。
struct AgentFileRowDisplay {
    enum Action: Equatable { case none, load, cancel, retry }

    let file: AgentFileReference
    /// 縮圖種類(PDF、圖片)的載入狀態;其他種類是 `nil`。
    let thumbnail: AgentFileLoads.State?
    let open: AgentFileLoads.OpenState?

    private var card: AgentFileCardDisplay { AgentFileCardDisplay(file: file) }
    private var openDisplay: AgentFileOpenDisplay { AgentFileOpenDisplay(state: open) }
    private var thumbnailDisplay: AgentFileThumbnailDisplay { AgentFileThumbnailDisplay(state: card.preview == .thumbnail ? thumbnail : nil) }

    /// 「動作 · 類型 · 大小」;下載中顯示進度,不能開或超過自動載入上限時顯示原因。
    var subtitle: String {
        if case .downloading(let received, let total) = open {
            let done = Int64(received).formatted(.byteCount(style: .file))
            guard total > 0 else { return String(localized: "Downloading · \(done)") }
            return String(localized: "Downloading · \(done) / \(Int64(total).formatted(.byteCount(style: .file)))")
        }
        if let note = openDisplay.note { return note }
        if let note = thumbnailDisplay.note {
            return thumbnailDisplay.offersLoad ? "\(card.originText) · \(card.kindText) · \(note)" : note
        }
        return card.summary
    }

    var action: Action {
        if openDisplay.offersCancel { return .cancel }
        if openDisplay.offersRetry || thumbnailDisplay.offersRetry { return .retry }
        if thumbnailDisplay.offersLoad { return .load }
        return .none
    }

    var progress: Double? { openDisplay.progress }
    var isDownloading: Bool { openDisplay.isDownloading }

    /// 縮圖框沒有縮圖時的角標:副檔名大寫(最多 5 字);沒有副檔名是空字串(畫面改用類型圖示)。
    var badge: String { String(file.fileExtension.uppercased().prefix(5)) }
}

/// 點開檔案(#228)的顯示規則。
struct AgentFileOpenDisplay {
    let state: AgentFileLoads.OpenState?

    /// 下載進度(0…1);還不知道總大小時 `nil`(不定進度)。
    var progress: Double? {
        guard case .downloading(let received, let total) = state, total > 0 else { return nil }
        return Double(received) / Double(total)
    }

    var isDownloading: Bool { if case .downloading = state { true } else { false } }
    var offersCancel: Bool { isDownloading }
    var offersOpen: Bool {
        switch state {
        case nil, .ready: true
        default: false
        }
    }

    var offersRetry: Bool { state == .failed }

    /// 下載好的快取檔(分享用)。
    var shareableFile: URL? { if case .ready(let file) = state { file } else { nil } }

    var note: String? {
        switch state {
        case .tooLarge(let size):
            String(localized: "Too large to open here (\(Int64(size).formatted(.byteCount(style: .file)))). Open it on the host.")
        case .missing: String(localized: "This file is no longer on the host.")
        case .denied: String(localized: "Purrdr doesn’t open files in this location.")
        case .unsupported: String(localized: "Opening files isn’t available for this host yet.")
        case .failed: String(localized: "Couldn’t download the file.")
        case .downloading, .ready, nil: nil
        }
    }
}

/// 檔案卡片：Agent 寫入或修改的檔案,緊湊單列(#465,設計稿第 30 組,更像 iOS 26 的附件列):
/// 左 46×56 縮圖(PDF 首頁、圖片,或副檔名角標／類型圖示)、中間「檔名 + 動作 · 類型 · 大小」、右側「Load／Cancel」文字鈕、
/// 下載中的進度條。內容層，不用玻璃。點整列下載到快取並以 QuickLook 預覽(#228);內容摘要、修改摘要與路徑在
/// 長按選單的「Details」(sheet),下載好了可分享。
struct AgentFileCardView: View {
    let card: AgentFileCard
    @Environment(\.agentImages) private var context
    @State private var previewFile: URL?
    @State private var showsDetails = false

    private var display: AgentFileCardDisplay { AgentFileCardDisplay(file: card.file) }
    private var openDisplay: AgentFileOpenDisplay { AgentFileOpenDisplay(state: context.loads?.opens[card.file.path]) }
    private var rowDisplay: AgentFileRowDisplay {
        AgentFileRowDisplay(file: card.file, thumbnail: context.loads?.states[card.file.path], open: context.loads?.opens[card.file.path])
    }

    var body: some View {
        let row = rowDisplay
        HStack(spacing: 12) {
            Button(action: primaryAction) {
                HStack(spacing: 12) {
                    AgentFileThumbnailView(card: card)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: card.file.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(verbatim: row.subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondaryText)
                            .lineLimit(2)
                            .accessibilityIdentifier("conversation.agentFile.subtitle")
                        if let progress = row.progress {
                            ProgressView(value: progress)
                                .accessibilityLabel(Text("Downloading \(card.file.name)"))
                                .accessibilityIdentifier("conversation.agentFile.progress")
                        } else if row.isDownloading {
                            ProgressView()
                                .accessibilityLabel(Text("Downloading \(card.file.name)"))
                                .accessibilityIdentifier("conversation.agentFile.progress")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: display.accessibilityLabel))
            .accessibilityHint(context.loads == nil ? Text(verbatim: "") : Text("Downloads the file from the host and shows a preview."))
            .accessibilityIdentifier("conversation.agentFile.row")
            if row.action != .none {
                Button { perform(row.action) } label: {
                    Self.actionTitle(row.action)
                        .font(.subheadline.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .accessibilityLabel(Self.actionLabel(row.action, name: card.file.name))
                .accessibilityIdentifier(Self.actionIdentifier(row.action))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 18))
        .listContextMenu {
            Button("Details", systemImage: "info.circle") { showsDetails = true }
            Button("Copy Path", systemImage: "document.on.document") { Clipboard.copy(card.file.path) }
            if let content = display.copyableContent {
                Button("Copy Content", systemImage: "document.on.document") { Clipboard.copy(content) }
            }
            if let file = openDisplay.shareableFile {
                ShareLink(item: file)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("Details")) { showsDetails = true }
        .accessibilityAction(named: Text("Copy Path")) { Clipboard.copy(card.file.path) }
        .accessibilityIdentifier("conversation.agentFile")
        .presentedQuickLook($previewFile)
        .presentedSheet(isPresented: $showsDetails) { AgentFileDetailsSheet(card: card, display: display) }
    }

    private static func actionTitle(_ action: AgentFileRowDisplay.Action) -> Text {
        switch action {
        case .none: Text(verbatim: "")
        case .load: Text("Load")
        case .cancel: Text("Cancel")
        case .retry: Text("Try Again")
        }
    }

    private static func actionLabel(_ action: AgentFileRowDisplay.Action, name: String) -> Text {
        switch action {
        case .none: Text(verbatim: "")
        case .load: Text("Load \(name)")
        case .cancel: Text("Cancel downloading \(name)")
        case .retry: Text("Try again \(name)")
        }
    }

    private static func actionIdentifier(_ action: AgentFileRowDisplay.Action) -> String {
        switch action {
        case .none, .load: "conversation.agentFile.load"
        case .cancel: "conversation.agentFile.cancel"
        case .retry: "conversation.agentFile.retry"
        }
    }

    private func perform(_ action: AgentFileRowDisplay.Action) {
        guard let loads = context.loads else { return }
        let path = card.file.path
        switch action {
        case .none: break
        case .cancel: loads.cancelOpen(path)
        case .load:
            let scope = context.scope()
            Task { await loads.load(path, scope: scope, userRequested: true) }
        case .retry:
            if openDisplay.offersRetry {
                open()
            } else {
                let scope = context.scope()
                let decodesWithImageIO = card.file.kind == .image
                Task { await loads.load(path, scope: scope, userRequested: false, decodesWithImageIO: decodesWithImageIO) }
            }
        }
    }

    /// 點整列:有主機通道就下載並以 QuickLook 開;沒有(離線唯讀)就看詳細。
    private func primaryAction() {
        guard context.loads != nil else { showsDetails = true; return }
        if openDisplay.offersOpen { open() }
    }

    /// 下載(版本沒變只查狀態)後以 QuickLook 開。
    private func open() {
        guard let loads = context.loads else { return }
        let scope = context.scope()
        Task { if let file = await loads.open(card.file.path, scope: scope) { previewFile = file } }
    }
}

/// 檔案卡片的詳細(#465):完整路徑、動作 · 類型 · 大小,以及對話紀錄裡的內容或修改摘要(原本在卡片內,緊湊單列後移到這裡)。
struct AgentFileDetailsSheet: View {
    let card: AgentFileCard
    let display: AgentFileCardDisplay

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(verbatim: card.file.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondaryText)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("conversation.agentFile.path")
                    Text(verbatim: display.summary)
                        .font(.footnote)
                        .foregroundStyle(.secondaryText)
                    if !display.lines.isEmpty {
                        ScrollView(.horizontal) {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(display.lines.enumerated()), id: \.offset) { _, line in
                                    Text(verbatim: line.text.isEmpty ? " " : line.text)
                                        .foregroundStyle(Self.style(of: line.kind))
                                        .fontWeight(line.kind == .added ? .semibold : .regular)
                                        .strikethrough(line.kind == .removed)
                                }
                            }
                            .font(.system(.footnote, design: .monospaced))
                            .fixedSize()
                            .textSelection(.enabled)
                        }
                        .scrollIndicators(.hidden)
                        .accessibilityIdentifier("conversation.agentFile.content")
                    }
                    if let note = display.truncationNote {
                        Text(note).font(.caption).foregroundStyle(.secondaryText)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(Text(verbatim: card.file.name))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { SheetCloseToolbar(identifier: "conversation.agentFile.details.close") }
        }
        .appSheet(detents: [.medium, .large])
        .accessibilityIdentifier("conversation.agentFile.details")
    }

    /// 新增的行主要色加粗、刪除的行次要文字色加刪除線、未變的行次要文字色;不用紅綠承載文字(#240),`+`／`-` 符號保留。
    private static func style(of kind: AgentFileCardDisplay.Line.Kind) -> AnyShapeStyle {
        switch kind {
        case .plain, .added: AnyShapeStyle(.primary)
        case .removed, .context, .hunkHeader: AnyShapeStyle(.secondaryText)
        }
    }
}

/// 檔案卡片與圖片卡片共用的標題列(#330):類型圖示、檔名與時間;路徑與「動作 · 類型 · 大小」是進階資訊,
/// 收在 `AgentFileCardDetails`。VoiceOver 念動作、檔名、類型、大小(不含路徑)。
struct AgentFileCardHeader: View {
    let card: AgentFileCard
    let display: AgentFileCardDisplay
    let identifier: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: display.symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(minWidth: 28)
                .accessibilityHidden(true)
            Text(verbatim: card.file.name)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
            if display.preview == .typeIcon, let byteCount = card.file.byteCount {
                Text(Int64(byteCount).formatted(.byteCount(style: .file)))
                    .font(.caption)
                    .foregroundStyle(.secondaryText)
                    .accessibilityIdentifier("conversation.agentFile.size")
            }
            if let date = card.date {
                Text(date, format: .dateTime.hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.secondaryText)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(display.accessibilityLabel)
        .accessibilityIdentifier(identifier)
    }
}

/// 卡片的進階資訊(#330,HIG Disclosure controls):預設收起，點「Details」才顯示完整路徑與「動作 · 類型 · 大小」。
/// 展開狀態存對話時間軸(列 id 加檔案路徑);沒有注入時(其他畫面)用本地狀態。
struct AgentFileCardDetails: View {
    let card: AgentFileCard
    let display: AgentFileCardDisplay
    let identifier: String
    private let expansion: ExpansionState

    init(card: AgentFileCard, display: AgentFileCardDisplay, identifier: String) {
        self.card = card
        self.display = display
        self.identifier = identifier
        expansion = ExpansionState(partID: "details:\(card.file.path)")
    }

    var body: some View {
        DisclosureGroup(isExpanded: expansion.binding) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: card.file.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondaryText)
                    .textSelection(.enabled)
                Text(verbatim: display.summary)
                    .font(.caption)
                    .foregroundStyle(.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Path: \(card.file.path)"))
            .accessibilityIdentifier("\(identifier).path")
        } label: {
            Text("Details")
                .font(.footnote)
                .foregroundStyle(.secondaryText)
                .frame(minHeight: 44, alignment: .leading)
                .accessibilityIdentifier("\(identifier).disclosure")
        }
    }
}

