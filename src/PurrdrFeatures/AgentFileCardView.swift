import Foundation
import PurrdrCore
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

    /// 「Created」「Overwritten」「Edited」。
    var originText: String {
        switch file.origin {
        case .created: String(localized: "Created")
        case .overwritten: String(localized: "Overwritten")
        case .edited: String(localized: "Edited")
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

    /// VoiceOver 念的標題：動作、檔名、類型、大小或增刪行數，最後是路徑。
    var accessibilityLabel: String {
        var parts = [String(localized: "\(originText) file \(file.name)"), kindText]
        if let byteCount = file.byteCount { parts.append(Int64(byteCount).formatted(.byteCount(style: .file))) }
        if case .edit(let change) = file.snapshot {
            parts.append(String(localized: "\(change.addedLines) lines added, \(change.removedLines) removed"))
        }
        parts.append(String(localized: "Path: \(file.path)"))
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

/// 檔案卡片：Agent 寫入或修改的檔案。標題列是類型圖示、檔名、路徑與「動作 · 類型 · 大小」,
/// 下方等寬顯示對話紀錄裡的內容或修改摘要(超過 8 行折疊)。內容層，不用玻璃;長按可複製路徑或內容。
struct AgentFileCardView: View {
    let card: AgentFileCard
    @State private var expanded = false

    private var display: AgentFileCardDisplay { AgentFileCardDisplay(file: card.file) }

    var body: some View {
        let visible = display.visibleLines(expanded: expanded)
        VStack(alignment: .leading, spacing: 8) {
            header
            if !visible.isEmpty {
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(visible.enumerated()), id: \.offset) { _, line in
                            Text(verbatim: line.text.isEmpty ? " " : line.text)
                                .foregroundStyle(Self.style(of: line.kind))
                                .fontWeight(line.kind == .added ? .semibold : .regular)
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
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conversation.agentFile")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: display.symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(minWidth: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: card.file.name)
                    .font(.subheadline.weight(.semibold))
                Text(verbatim: card.file.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondaryText)
                Text(verbatim: display.summary)
                    .font(.caption)
                    .foregroundStyle(.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let date = card.date {
                Text(date, format: .dateTime.hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.secondaryText)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(display.accessibilityLabel)
        .accessibilityIdentifier("conversation.agentFile.header")
    }

    /// 刪除的行用錯誤文字色、未變的行用次要文字色;新增的行用主要文字色加粗(沒有對比足夠的綠色角色)。
    private static func style(of kind: AgentFileCardDisplay.Line.Kind) -> AnyShapeStyle {
        switch kind {
        case .plain, .added: AnyShapeStyle(.primary)
        case .removed: AnyShapeStyle(.errorText)
        case .context, .hunkHeader: AnyShapeStyle(.secondaryText)
        }
    }
}
