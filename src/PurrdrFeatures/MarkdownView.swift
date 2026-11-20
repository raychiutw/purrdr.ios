import PurrdrCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// agent 文字的 markdown(行為規格 F5.10)。全寬、內容層、不用 Liquid Glass。
struct MarkdownView: View {
    let blocks: [MarkdownBlock]

    init(_ markdown: String) {
        blocks = Markdown.parse(markdown)
    }

    /// 有程式碼區塊或表格(含引言裡的)。
    var hasStructuredBlocks: Bool {
        func structured(_ block: MarkdownBlock) -> Bool {
            switch block {
            case .code, .table: true
            case .quote(let inner): inner.contains(where: structured)
            case .paragraph, .heading, .list, .rule: false
            }
        }
        return blocks.contains(where: structured)
    }

    /// 有可點的主機路徑(#229):合併成一個元素時 iOS 27 不再把文字裡的連結交給 VoiceOver 與 UI 測試(#251)。
    var hasHostPaths: Bool {
        func inline(_ items: [MarkdownInline]) -> Bool {
            items.contains { item in
                switch item {
                case .hostPath: true
                case .strong(let children), .emphasis(let children), .link(let children, _): inline(children)
                case .text, .code: false
                }
            }
        }
        func mentions(_ block: MarkdownBlock) -> Bool {
            switch block {
            case .paragraph(let items), .heading(_, let items): inline(items)
            case .list(_, _, let items): items.contains(where: inline)
            case .quote(let inner): inner.contains(where: mentions)
            case .rule, .code, .table: false
            }
        }
        return blocks.contains(where: mentions)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                BlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .paragraph(let inlines):
            InlineText(inlines)
        case .heading(let level, let inlines):
            InlineText(inlines)
                .font(level <= 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .accessibilityAddTraits(.isHeader)
        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(ordered ? "\(start + index)." : "•")
                            .monospacedDigit()
                            .foregroundStyle(.secondaryText)
                        InlineText(item)
                    }
                }
            }
        case .quote(let blocks):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.tertiary)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        BlockView(block: block)
                    }
                }
                .foregroundStyle(.secondaryText)
            }
        case .rule:
            Divider()
        case .code(let language, let text):
            CodeBlockView(language: language, code: text)
        case .table(let table):
            TableView(table: table)
        }
    }
}

/// 行內文字：連結只會是 http(s)(解析時已過濾)與主機路徑(#229);行內 code 用等寬字、**沒有底色**(iOS 換行時底色會畫成一條)。
struct InlineText: View {
    let inlines: [MarkdownInline]

    init(_ inlines: [MarkdownInline]) {
        self.inlines = inlines
    }

    var body: some View {
        Text(Self.attributed(inlines))
            .textSelection(.enabled)
            // 連結顏色跟 tint 走，也就是主色(ADR-0011)。
            .fixedSize(horizontal: false, vertical: true)
    }

    static func attributed(_ inlines: [MarkdownInline], bold: Bool = false, italic: Bool = false) -> AttributedString {
        var result = AttributedString()
        for inline in inlines {
            switch inline {
            case .text(let text):
                var run = AttributedString(text)
                run.inlinePresentationIntent = intent(bold: bold, italic: italic)
                result += run
            case .code(let code):
                var run = AttributedString(code)
                run.inlinePresentationIntent = intent(bold: bold, italic: italic).union(.code)
                result += run
            case .strong(let children):
                result += attributed(children, bold: true, italic: italic)
            case .emphasis(let children):
                result += attributed(children, bold: bold, italic: true)
            case .link(let children, let url):
                var run = attributed(children, bold: bold, italic: italic)
                run.link = URL(string: url)
                run.underlineStyle = .single
                result += run
            case .hostPath(let children, let path):
                // 點了由 `AgentMessageView` 的 openURL 攔下，在 app 內開(#229)。
                var run = attributed(children, bold: bold, italic: italic)
                run.link = HostPathMention.linkURL(for: path)
                run.underlineStyle = .single
                result += run
            }
        }
        return result
    }

    private static func intent(bold: Bool, italic: Bool) -> InlinePresentationIntent {
        var intent: InlinePresentationIntent = []
        if bold { intent.insert(.stronglyEmphasized) }
        if italic { intent.insert(.emphasized) }
        return intent
    }
}

/// 程式碼區塊：等寬、跟隨 Dynamic Type、**永不換行**而是在自己的容器內橫捲、可選取;頂列語言 + 複製鈕。
struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? String(localized: "Code"))
                    .font(.caption)
                    .foregroundStyle(.secondaryText)
                Spacer()
                // 空的區塊不提供複製：複製空字串會清空剪貼簿(R-V04)。
                if !code.isEmpty {
                    Button {
                        Clipboard.copy(Self.copyText(code))
                        copied = code
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            if copied == code { copied = nil }
                        }
                    } label: {
                        Label(copied == code ? "Copied" : "Copy Code", systemImage: copied == code ? "checkmark" : "document.on.document")
                            .labelStyle(.iconOnly)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondaryText)
                    .accessibilityIdentifier("conversation.code.copy")
                }
            }
            .padding(.leading, 12)
            ScrollView(.horizontal) {
                Text(code)
                    .font(.callout.monospaced())
                    .fixedSize(horizontal: true, vertical: false)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
            .accessibilityIdentifier("conversation.code")
        }
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    /// 複製的程式碼去掉結尾換行、CRLF 轉 LF。
    static func copyText(_ code: String) -> String {
        var text = code.replacingOccurrences(of: "\r\n", with: "\n")
        while text.hasSuffix("\n") { text.removeLast() }
        return text
    }
}

/// GFM 表格：逐欄對齊;寬於螢幕時在自己的容器內橫捲(頁面永不橫捲)。
struct TableView: View {
    let table: MarkdownTable

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(table.header.enumerated()), id: \.offset) { column, cell in
                        InlineText(cell)
                            .font(.subheadline.bold())
                            .gridColumnAlignment(alignment(column))
                    }
                }
                Divider()
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            InlineText(cell)
                                .font(.subheadline)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .accessibilityIdentifier("conversation.table")
    }

    private func alignment(_ column: Int) -> HorizontalAlignment {
        guard column < table.alignments.count else { return .leading }
        switch table.alignments[column] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

/// 系統剪貼簿。
enum Clipboard {
    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
