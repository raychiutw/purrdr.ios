import Foundation
import PurrdrCore
import PurrdrDemo
import Testing

/// Demo 主機的「需要你」情境(行為規格 F21):畫面、按鍵與狀態變化都走正式的 client 指令。
@Suite("Demo 主機：回答需要你")
struct DemoAnswerTests {
    static func status(_ paneID: String, on host: DemoHost) async throws -> AgentStatus? {
        try await HerdrClient(channel: host).snapshot().agents.first { $0.paneID == paneID }?.status
    }

    static func prompt(_ paneID: String, on host: DemoHost) async throws -> BlockedPrompt? {
        BlockedPromptParser.parse(screen: try await HerdrClient(channel: host).readPane(paneID: paneID), agentKind: "claude")
    }

    @Test("weather-app 卡在 Bash 權限：畫面上有問題與三個選項;回答 1 後不再需要你")
    func bashPermissionResolvesAfterAnswer() async throws {
        let host = DemoHost()
        let prompt = try #require(try await Self.prompt("w2:p1", on: host))
        #expect(prompt.kind == .menu)
        #expect(prompt.details?.title == "Bash command")
        #expect(prompt.options.count == 3)

        try await HerdrClient(channel: host).sendKeys(paneID: "w2:p1", keys: ["1"])

        #expect(try await Self.status("w2:p1", on: host) == .done)
        #expect(try await Self.prompt("w2:p1", on: host) == nil)
    }

    @Test("Bash 權限：數字加 Enter(錯的按鍵規則)不算回答")
    func digitWithEnterDoesNotAnswerClaude() async throws {
        let host = DemoHost()

        try await HerdrClient(channel: host).sendKeys(paneID: "w2:p1", keys: ["1", "enter"])

        #expect(try await Self.status("w2:p1", on: host) == .blocked)
    }

    @Test("觸發語「ask me」:ledger 進入兩題 AskUserQuestion,逐題數字作答後到檢閱畫面，送出後回到完成")
    func askUserQuestionScenario() async throws {
        let host = DemoHost()
        let client = HerdrClient(channel: host)
        _ = try await client.prompt(target: "w1:p1", text: "ask me", wait: .seconds(8))
        #expect(try await Self.status("w1:p1", on: host) == .blocked)
        #expect(try await Self.prompt("w1:p1", on: host)?.question == "Which color should the chart use?")

        try await client.sendKeys(paneID: "w1:p1", keys: ["2"])
        #expect(try await Self.prompt("w1:p1", on: host)?.question == "How large should the chart be?")

        try await client.sendKeys(paneID: "w1:p1", keys: ["1"])
        let review = try #require(try await Self.prompt("w1:p1", on: host))
        #expect(review.question == "Ready to submit your answers?")

        try await client.sendKeys(paneID: "w1:p1", keys: ["1"])
        #expect(try await Self.status("w1:p1", on: host) == .done)
    }

    @Test("ask me 的「Type something.」:數字只把那一列變成文字輸入，之後的數字鍵變成那一列的文字，不算回答(#120 症狀)")
    func typeSomethingDigitOpensInlineInput() async throws {
        let host = DemoHost()
        let client = HerdrClient(channel: host)
        _ = try await client.prompt(target: "w1:p1", text: "ask me", wait: .seconds(8))

        try await client.sendKeys(paneID: "w1:p1", keys: ["4"])
        let typing = try #require(try await Self.prompt("w1:p1", on: host))
        #expect(typing.question == "Which color should the chart use?")
        #expect(typing.options.last == PromptOption(number: 4, label: "Type something.", isCursor: true))

        try await client.sendKeys(paneID: "w1:p1", keys: ["1"])
        let typed = try #require(try await Self.prompt("w1:p1", on: host))
        #expect(typed.question == "Which color should the chart use?")
        #expect(typed.options.last == PromptOption(number: 4, label: "1", isCursor: true))
        #expect(try await Self.status("w1:p1", on: host) == .blocked)
    }

    @Test("ask me 的「Type something.」:數字 → 文字 → enter 才算回答，進到下一題")
    func typeSomethingAnswersWithTextThenEnter() async throws {
        let host = DemoHost()
        let client = HerdrClient(channel: host)
        _ = try await client.prompt(target: "w1:p1", text: "ask me", wait: .seconds(8))

        try await client.sendKeys(paneID: "w1:p1", keys: ["4"])
        try await client.sendText(paneID: "w1:p1", text: "綠色 green")
        #expect(try await Self.prompt("w1:p1", on: host)?.options.last?.label == "綠色 green")
        try await client.sendKeys(paneID: "w1:p1", keys: ["enter"])

        #expect(try await Self.prompt("w1:p1", on: host)?.question == "How large should the chart be?")
    }

    @Test("沒進文字輸入時 send_text 不算回答")
    func textWithoutTypeSomethingDoesNotAnswer() async throws {
        let host = DemoHost()
        let client = HerdrClient(channel: host)
        _ = try await client.prompt(target: "w1:p1", text: "ask me", wait: .seconds(8))

        try await client.sendText(paneID: "w1:p1", text: "teal")
        try await client.sendKeys(paneID: "w1:p1", keys: ["enter"])

        #expect(try await Self.prompt("w1:p1", on: host)?.question == "Which color should the chart use?")
    }

    @Test("觸發語「trust」:ledger 顯示資料夾信任(狀態仍是閒置、prompt 被 agent_input_pending 拒絕);down+enter 信任後恢復")
    func trustScenario() async throws {
        let host = DemoHost()
        let client = HerdrClient(channel: host)
        _ = try await client.prompt(target: "w1:p1", text: "trust", wait: .seconds(8))

        #expect(try await Self.status("w1:p1", on: host) == .done)
        #expect(try await Self.prompt("w1:p1", on: host)?.kind == .trust)
        await #expect(throws: HerdrError.herdr(code: "agent_input_pending", message: "agent is waiting for input; answer it first")) {
            _ = try await client.prompt(target: "w1:p1", text: "hello", wait: .seconds(8))
        }

        try await client.sendKeys(paneID: "w1:p1", keys: ["down", "enter"])

        #expect(try await Self.prompt("w1:p1", on: host) == nil)
    }
}
