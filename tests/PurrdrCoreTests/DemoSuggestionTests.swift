import Foundation
import PurrdrCore
import PurrdrDemo
import Testing

/// Demo 主機的建議提示詞(#123):ledger(完成的 Claude Code)畫面輸入列帶灰色建議，送出 prompt 後換下一句、最後消失。
@Suite("Demo 主機：建議提示詞")
struct DemoSuggestionTests {
    static func suggestion(on host: DemoHost, paneID: String = "w1:p1") async throws -> String? {
        PromptSuggestion.detect(screen: try await HerdrClient(channel: host).readPane(paneID: paneID, format: .ansi))
    }

    @Test("ledger 的含 ANSI 畫面有建議;純文字畫面看不出灰色，也就沒有跳脫序列")
    func ledgerHasSuggestion() async throws {
        let host = DemoHost()

        #expect(try await Self.suggestion(on: host) == "Add a test for CSV export with commas in the memo")
        let text = try await HerdrClient(channel: host).readPane(paneID: "w1:p1")
        #expect(!text.contains("\u{1B}"))
        #expect(text.contains("❯\u{00A0}Add a test for CSV export with commas in the memo"))
    }

    @Test("送出 prompt 後換下一句，再送就沒有建議;開面板的 slash 指令不算")
    func promptAdvancesSuggestion() async throws {
        let host = DemoHost()
        let client = HerdrClient(channel: host)

        _ = try await client.prompt(target: "w1:p1", text: "/model", wait: nil)
        try await client.sendKeys(paneID: "w1:p1", keys: ["esc"])
        #expect(try await Self.suggestion(on: host) == "Add a test for CSV export with commas in the memo")

        _ = try await client.prompt(target: "w1:p1", text: "Add a test for CSV export with commas in the memo", wait: nil)
        #expect(try await Self.suggestion(on: host) == "Run the tests")

        _ = try await client.prompt(target: "w1:p1", text: "hello", wait: nil)
        #expect(try await Self.suggestion(on: host) == nil)
    }

    @Test("其他 Agent(需要你的 weather-app、工作中的 Codex)沒有建議")
    func otherPanesHaveNone() async throws {
        let host = DemoHost()
        #expect(try await Self.suggestion(on: host, paneID: "w2:p1") == nil)
        #expect(try await Self.suggestion(on: host, paneID: "w3:p1") == nil)
    }
}
