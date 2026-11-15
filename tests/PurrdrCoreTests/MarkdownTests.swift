import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// agent 文字的 markdown(行為規格 F5.10、R-V03)。
@Suite("Markdown")
struct MarkdownTests {
    typealias Inline = MarkdownInline

    @Test("區塊：標題、段落、清單(保留起始號)、引用、水平線、圍欄程式碼")
    func parsesBlocks() {
        let blocks = Markdown.parse("""
        ## 結果
        欄位順序改好了。
        第二行同一段。

        3. 第三步
        4) 第四步
        - 一
        * 二

        > 引用

        ---
        ```swift
        let x = 1
        ```
        """)

        #expect(blocks == [
            .heading(level: 2, [.text("結果")]),
            .paragraph([.text("欄位順序改好了。\n第二行同一段。")]),
            .list(ordered: true, start: 3, items: [[.text("第三步")], [.text("第四步")]]),
            .list(ordered: false, start: 1, items: [[.text("一")], [.text("二")]]),
            .quote([.paragraph([.text("引用")])]),
            .rule,
            .code(language: "swift", text: "let x = 1"),
        ])
    }

    /// #108:只有同字元、長度 ≥ 開頭、且該行沒有其他內容的圍欄才關閉。
    @Test("圍欄：較短的圍欄、不同字元、後面還有字的行都不關閉")
    func fenceClosesOnlyOnMatchingLine() {
        let blocks = Markdown.parse("""
        ````markdown
        ```swift
        let x = 1
        ```
        ~~~
        ```` trailing
        ````
        after
        """)

        #expect(blocks == [
            .code(language: "markdown", text: "```swift\nlet x = 1\n```\n~~~\n```` trailing"),
            .paragraph([.text("after")]),
        ])
    }

    @Test("沒有關閉的圍欄延伸到結尾")
    func unclosedFenceRunsToEnd() {
        #expect(Markdown.parse("```\na\nb") == [.code(language: nil, text: "a\nb")])
    }

    @Test("表格：短列補齊、多的格併回最後一格、\\| 是字面、程式碼內的 | 不分格、依 :-- :-: --: 對齊")
    func parsesTables() {
        let blocks = Markdown.parse("""
        | 欄位 | 型別 | 對齊 |
        |:--|:-:|--:|
        | date | `String` |
        | note | `a | b` | 右 | 多 |
        | x \\| y | z | w |
        """)

        #expect(blocks == [
            .table(MarkdownTable(
                alignments: [.leading, .center, .trailing],
                header: [[.text("欄位")], [.text("型別")], [.text("對齊")]],
                rows: [
                    [[.text("date")], [.code("String")], []],
                    [[.text("note")], [.code("a | b")], [.text("右 | 多")]],
                    [[.text("x | y")], [.text("z")], [.text("w")]],
                ]
            )),
        ])
    }

    /// 只有 http/https 且有主機的連結可點;其他 scheme 與相對路徑當純文字(R-V03)。
    @Test("連結：只有 http(s) 且有主機的才是連結，其他只留文字")
    func onlyHTTPLinksAreLinks() {
        #expect(Markdown.inlines("見 [RFC](https://www.rfc-editor.org/rfc/rfc4180)") ==
            [.text("見 "), .link(text: [.text("RFC")], url: "https://www.rfc-editor.org/rfc/rfc4180")])
        #expect(Markdown.inlines("[本機](file:///Users/demo/a.md)") == [.text("本機")])
        #expect(Markdown.inlines("[相對](docs/a.md)") == [.text("相對")])
        #expect(Markdown.inlines("[js](javascript:alert(1))") == [.text("js")])
        #expect(Markdown.inlines("[沒主機](https:///path)") == [.text("沒主機")])
        #expect(Markdown.inlines("[w](https://en.wikipedia.org/wiki/Foo_(bar))") ==
            [.link(text: [.text("w")], url: "https://en.wikipedia.org/wiki/Foo_(bar)")])
    }

    @Test("自動連結：裸 https:// 與 <https://…>,結尾標點不算")
    func autolinks() {
        #expect(Markdown.inlines("看 https://example.com/a.") ==
            [.text("看 "), .link(text: [.text("https://example.com/a")], url: "https://example.com/a"), .text(".")])
        #expect(Markdown.inlines("<https://example.com>") ==
            [.link(text: [.text("https://example.com")], url: "https://example.com")])
        #expect(Markdown.inlines("<file:///etc/passwd>") == [.text("<file:///etc/passwd>")])
    }

    @Test("行內：code、粗體、斜體;識別字中的底線是字面;粗體中的 code 保持 code")
    func inlineEmphasisAndCode() {
        #expect(Markdown.inlines("改 `snake_case` 與 snake_case_name 的 **重點 `x`** 和 *斜* _體_") == [
            .text("改 "), .code("snake_case"), .text(" 與 snake_case_name 的 "),
            .strong([.text("重點 "), .code("x")]), .text(" 和 "), .emphasis([.text("斜")]), .text(" "), .emphasis([.text("體")]),
        ])
    }

    @Test("真實對話紀錄的 agent 文字：表格、程式碼區塊與連結")
    func fixtureReplyParses() throws {
        let messages = ClaudeTranscriptParser.messages(in: Fixtures.transcriptLines()[27])
        guard case .text(let markdown) = try #require(messages.first?.parts.first) else {
            Issue.record("第 27 行不是 agent 文字")
            return
        }

        let blocks = Markdown.parse(markdown)

        #expect(blocks.count == 4)
        #expect(blocks[2] == .code(language: "swift", text: #"static let columns = ["date", "amount", "note"]"#))
        guard case .paragraph(let last) = blocks[3] else {
            Issue.record("最後一段不是段落")
            return
        }
        #expect(last == [
            .text("細節見 "), .link(text: [.text("RFC 4180")], url: "https://www.rfc-editor.org/rfc/rfc4180"), .text(" 與 本機檔案。"),
        ])
    }
}
