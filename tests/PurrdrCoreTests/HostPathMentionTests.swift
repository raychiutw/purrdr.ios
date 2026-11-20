import Foundation
import PurrdrCore
import Testing

/// 訊息文字中的主機路徑(#229):辨識規則、可點的 markdown 與存取範圍。
@Suite("訊息內主機路徑")
struct HostPathMentionTests {
    struct Vector: Decodable {
        var name: String
        var text: String
        var paths: [String]
    }

    /// 與主機服務共用的案例(`vendor/purrdr-host/protocol/host-path-mentions.json`)。
    static let vectors: [Vector] = {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        struct File: Decodable { var cases: [Vector] }
        let data = (try? Data(contentsOf: root.appending(path: "vendor/purrdr-host/protocol/host-path-mentions.json"))) ?? Data()
        return (try? JSONDecoder().decode(File.self, from: data).cases) ?? []
    }()

    @Test("共用案例：POSIX、Windows、含空白與中文;網址與相對路徑不算")
    func sharedVectors() {
        #expect(Self.vectors.count >= 20)
        for vector in Self.vectors {
            #expect(HostPathMention.paths(in: vector.text) == vector.paths, "\(vector.name)")
        }
    }

    @Test("markdown:文字與行內 code 中的主機路徑可點;粗體裡也算，網址仍是連結")
    func markdownMarksHostPaths() {
        #expect(Markdown.inlines("報告在 /Users/demo/報告.pdf。") == [
            .text("報告在 "), .hostPath(text: [.text("/Users/demo/報告.pdf")], path: "/Users/demo/報告.pdf"), .text("。"),
        ])
        #expect(Markdown.inlines("Open `/Users/demo/My Report.pdf:3` or `ls /tmp/a/b`") == [
            .text("Open "), .hostPath(text: [.code("/Users/demo/My Report.pdf:3")], path: "/Users/demo/My Report.pdf"),
            .text(" or "), .code("ls /tmp/a/b"),
        ])
        #expect(Markdown.inlines(#"**C:\Temp\run.log** 與 https://example.com/a/b"#) == [
            .strong([.hostPath(text: [.text(#"C:\Temp\run.log"#)], path: #"C:\Temp\run.log"#)]), .text(" 與 "),
            .link(text: [.text("https://example.com/a/b")], url: "https://example.com/a/b"),
        ])
    }

    @Test("可點路徑的連結：只在 app 內處理，路徑含空白、中文、# & + 也能還原;其他網址不是路徑")
    func linkRoundTrip() throws {
        let path = #"C:\Users\Demo\報告 #1 & 2+.pdf"#
        let url = try #require(HostPathMention.linkURL(for: path))

        #expect(url.scheme != "http" && url.scheme != "https" && url.scheme != "file")
        #expect(HostPathMention.path(fromLink: url) == path)
        #expect(HostPathMention.path(fromLink: try #require(URL(string: "https://example.com/Users/demo/a.pdf"))) == nil)
    }

    @Test("點連結時系統交回的是 NSURL 橋接的網址：沒有 `//` 的網址舊解析器讀不到 query,也要還原路徑")
    func linkFromBridgedURL() throws {
        // iPhone 17 實測(#251):SwiftUI 點文字連結交給 openURL 的網址 absoluteString 相同，`query` 卻是 nil,路徑沒開。
        let path = "/Users/demo/ledger/docs/export-report.pdf"
        let link = try #require(HostPathMention.linkURL(for: path))
        let bridged = try #require(NSURL(string: link.absoluteString)) as URL
        #expect(HostPathMention.path(fromLink: bridged) == path)
    }

    @Test("對話紀錄出現過的路徑：檔案卡片的路徑，加上 Agent 訊息文字中的路徑(含工作目錄外)")
    func mentionedPathsIncludeMessageText() {
        let items: [ConversationItem] = [
            .agentFile(AgentFileCard(id: "f1", file: AgentFileReference(origin: .created, path: "/Users/demo/ledger/a.swift"), date: nil)),
            .agentText(AgentText(id: "t1", markdown: "報告在 `/Users/demo/Desktop/My Report.pdf`,log 在 C:\\Temp\\run.log。", date: nil)),
            .user(UserBubble(id: "u1", text: "/Users/demo/secret/notes.txt", date: nil, imageCount: 0)),
        ]

        #expect(HostFileAccessScope.mentionedPaths(in: items) == [
            "/Users/demo/ledger/a.swift", "/Users/demo/Desktop/My Report.pdf", #"C:\Temp\run.log"#,
        ])
    }
}
