import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import QuickLook
import SwiftUI

/// 檔案卡片的顯示規則(#224)。
struct AgentFileCardDisplay {
    /// 內容超過這麼多行就折疊。
    static let foldLimit = 8

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

    var symbol: String {
        switch file.kind {
        case .text, .markdown: "doc.text"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .data: "tablecells"
        case .other: "doc"
        }
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

    var isFoldable: Bool { lines.count > Self.foldLimit }

    func visibleLines(expanded: Bool) -> [Line] {
        expanded || !isFoldable ? lines : Array(lines.prefix(Self.foldLimit))
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
            String(localized: "Too large to open here (\(Int64(size).formatted(.byteCount(style: .file)))). Open it on the computer.")
        case .missing: String(localized: "This file is no longer on the computer.")
        case .denied: String(localized: "Purrdr doesn’t open files in this location.")
        case .unsupported: String(localized: "Opening files isn’t available for this computer yet.")
        case .failed: String(localized: "Couldn’t download the file.")
        case .downloading, .ready, nil: nil
        }
    }
}

/// 檔案卡片：Agent 寫入或修改的檔案。標題列是類型圖示、檔名、路徑與「動作 · 類型 · 大小」,
/// 下方等寬顯示對話紀錄裡的內容或修改摘要(超過 8 行折疊)。內容層，不用玻璃;長按可複製路徑或內容。
/// 點標題列或「Open」才從主機下載到快取，以 QuickLook 預覽(#228);下載好了可分享。
struct AgentFileCardView: View {
    let card: AgentFileCard
    @State private var expanded = false
    @Environment(\.agentImages) private var context
    @State private var previewFile: URL?

    private var display: AgentFileCardDisplay { AgentFileCardDisplay(file: card.file) }
    private var openDisplay: AgentFileOpenDisplay { AgentFileOpenDisplay(state: context.loads?.opens[card.file.path]) }

    var body: some View {
        let visible = display.visibleLines(expanded: expanded)
        VStack(alignment: .leading, spacing: 8) {
            // 標題列本身可點(VoiceOver 是按鈕);保留它的 identifier 與完整標籤，所以不包成 Button。
            AgentFileCardHeader(card: card, display: display, identifier: "conversation.agentFile.header")
                .contentShape(Rectangle())
                .onTapGesture { if openDisplay.offersOpen { open() } }
                .accessibilityAddTraits(context.loads == nil ? [] : .isButton)
                .accessibilityHint(context.loads == nil ? Text(verbatim: "") : Text("Downloads the file from the computer and shows a preview."))
                .accessibilityAction { if openDisplay.offersOpen { open() } }
            AgentFileCardDetails(card: card, display: display, identifier: "conversation.agentFile")
            if context.loads != nil {
                AgentFileOpenRow(card: card, display: openDisplay, open: open, cancel: { context.loads?.cancelOpen(card.file.path) })
            }
            if !visible.isEmpty {
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(visible.enumerated()), id: \.offset) { _, line in
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
            if display.isFoldable || display.truncationNote != nil {
                HStack {
                    if let note = display.truncationNote {
                        Text(note)
                    }
                    Spacer()
                    if display.isFoldable {
                        Button { expanded.toggle() } label: {
                            (expanded ? Text("Show Less") : Text("Show All"))
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("conversation.agentFile.toggle")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondaryText)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
        .contextMenu {
            Button("Copy Path", systemImage: "document.on.document") { Clipboard.copy(card.file.path) }
            if let content = display.copyableContent {
                Button("Copy Content", systemImage: "document.on.document") { Clipboard.copy(content) }
            }
            if let file = openDisplay.shareableFile {
                ShareLink(item: file)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("Copy Path")) { Clipboard.copy(card.file.path) }
        .accessibilityIdentifier("conversation.agentFile")
        .quickLookPreview($previewFile)
    }

    /// 下載(版本沒變只查狀態)後以 QuickLook 開。
    private func open() {
        guard let loads = context.loads else { return }
        let scope = context.scope()
        Task { if let file = await loads.open(card.file.path, scope: scope) { previewFile = file } }
    }

    /// 新增的行主要色加粗、刪除的行次要文字色加刪除線、未變的行次要文字色;不用紅綠承載文字(#240),`+`／`-` 符號保留。
    private static func style(of kind: AgentFileCardDisplay.Line.Kind) -> AnyShapeStyle {
        switch kind {
        case .plain, .added: AnyShapeStyle(.primary)
        case .removed, .context, .hunkHeader: AnyShapeStyle(.secondaryText)
        }
    }
}

/// 檔案卡片的開啟列(#228):「Open」與「Share」,下載中是進度與「Cancel」,不能開時是原因(與「Try Again」)。
struct AgentFileOpenRow: View {
    let card: AgentFileCard
    let display: AgentFileOpenDisplay
    let open: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if display.isDownloading {
                Group {
                    if let progress = display.progress {
                        ProgressView(value: progress)
                    } else {
                        ProgressView()
                    }
                }
                .accessibilityLabel(Text("Downloading \(card.file.name)"))
                .accessibilityIdentifier("conversation.agentFile.progress")
                Button("Cancel", action: cancel)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("conversation.agentFile.cancel")
            } else if let note = display.note {
                Text(note)
                    .foregroundStyle(.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("conversation.agentFile.note")
                if display.offersRetry {
                    Button("Try Again", action: open)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("conversation.agentFile.retry")
                }
            } else {
                Button(action: open) {
                    Label("Open", systemImage: "eye")
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text("Open \(card.file.name)"))
                .accessibilityHint(Text("Downloads the file from the computer and shows a preview."))
                .accessibilityIdentifier("conversation.agentFile.open")
                if let file = display.shareableFile {
                    ShareLink(item: file) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(Text("Share \(card.file.name)"))
                    .accessibilityIdentifier("conversation.agentFile.share")
                }
                Spacer(minLength: 0)
            }
        }
        .font(.footnote)
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
/// 展開狀態是每張卡片自己的 `@State`;列表是 lazy 的，捲出畫面再回來會回到收起(預設)。
struct AgentFileCardDetails: View {
    let card: AgentFileCard
    let display: AgentFileCardDisplay
    let identifier: String
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
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

