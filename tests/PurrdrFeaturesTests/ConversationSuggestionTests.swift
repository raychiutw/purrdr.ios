import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 聊天視窗的建議提示詞(#121、#123):Claude Code 完成時，輸入列上方顯示 Pane 畫面輸入列裡的灰色建議;
/// 接受只填入輸入框、不送任何 herdr 請求。herdr 走假主機，畫面是 #122 的真實錄製(`pane.read.ansi.*`)。
@MainActor
@Suite("建議提示詞(聊天)")
struct ConversationSuggestionTests {
    typealias Setup = ConversationAnswerTests.Setup
    static let bridge = HerdrCommand.bridge()

    static func snapshot(status: String, kind: String = "claude") -> FakeReply {
        ConversationAnswerTests.snapshot(status: status, kind: kind)
    }

    /// 錄製的含 ANSI 畫面(Claude Code 2.1.326)。
    static func ansiScreen(_ name: String) -> FakeReply {
        .recorded("pane.read.ansi.\(name).ndjson")
    }

    static func ansiReads(_ setup: Setup) async -> Int {
        await setup.host.bridge.executions.filter {
            $0.stdinText.contains(#""method":"pane.read""#) && $0.stdinText.contains(#""format":"ansi""#)
        }.count
    }

    /// 陷阱：多讀一次畫面就會被用掉(假主機對沒預期的指令直接丟錯，被 `try?` 吞掉，所以「沒讀」要靠它看出來)。
    static func trap(_ setup: Setup) async {
        await setup.host.bridge.expect(bridge, reply: ansiScreen("suggestion"))
    }

    /// 完成的 Claude Code,畫面輸入列有建議。
    static func withSuggestion() async throws -> Setup {
        let setup = try ConversationAnswerTests.setup()
        await setup.host.bridge.expect(bridge, reply: snapshot(status: "done"))
        await setup.host.bridge.expect(bridge, reply: ansiScreen("suggestion"))
        await setup.model.poll()
        return setup
    }

    @Test("Claude Code 完成：讀一次含 ANSI 的畫面，顯示輸入列的建議")
    func doneClaudeShowsSuggestion() async throws {
        let setup = try await Self.withSuggestion()

        #expect(setup.model.suggestion == "add subtract to calc.py")
        #expect(await Self.ansiReads(setup) == 1)
        #expect(await setup.host.bridge.unmetExpectations.isEmpty)
    }

    @Test("接受建議：輸入框是建議文字，不送任何 herdr 請求;之後建議不再顯示(輸入框非空)")
    func acceptFillsDraftWithoutSending() async throws {
        let setup = try await Self.withSuggestion()
        // 備好送出的回應：真的送出就會被用掉。
        await ConversationSlashPanelTests.expectSlashSend(setup)
        let executionsBefore = await setup.host.bridge.executions.count
        let shellBefore = await setup.host.shellCommands.count

        #expect(setup.model.acceptSuggestion())

        #expect(setup.model.draft == "add subtract to calc.py")
        #expect(setup.model.suggestion == nil)
        #expect(await setup.host.bridge.executions.count == executionsBefore)
        #expect(await setup.host.shellCommands.count == shellBefore)
        #expect(setup.model.echoes.isEmpty)
    }

    @Test("Pane 輸入列上是使用者打的字(不是灰色建議):不顯示")
    func typedTextIsNotSuggestion() async throws {
        let setup = try ConversationAnswerTests.setup()
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "done"))
        await setup.host.bridge.expect(Self.bridge, reply: Self.ansiScreen("typed"))

        await setup.model.poll()

        #expect(setup.model.suggestion == nil)
        #expect(await Self.ansiReads(setup) == 1)
    }

    @Test(
        "工作中、需要你、非 Claude 的 Agent:不讀含 ANSI 的畫面、不顯示建議",
        arguments: [("working", "claude"), ("blocked", "claude"), ("done", "codex"), ("idle", "codex")]
    )
    func notCompletedClaudeHasNoSuggestion(status: String, kind: String) async throws {
        let setup = try ConversationAnswerTests.setup()
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: status, kind: kind))
        // 工作中(即時預覽)與需要你(提示)照舊讀純文字畫面。
        if status == "working" || status == "blocked" {
            await setup.host.bridge.expect(Self.bridge, reply: PaneScreens.read("claude-idle"))
        }
        await Self.trap(setup)

        await setup.model.poll()

        #expect(setup.model.suggestion == nil)
        #expect(await Self.ansiReads(setup) == 0)
        #expect(await setup.host.bridge.unmetExpectations.count == 1)
    }

    @Test("輸入框已有字：不顯示建議、接受不蓋掉;清空後建議再出現")
    func nonEmptyDraftHidesSuggestion() async throws {
        let setup = try await Self.withSuggestion()
        setup.model.draft = "my own words"

        #expect(setup.model.suggestion == nil)
        #expect(setup.model.acceptSuggestion() == false)
        #expect(setup.model.draft == "my own words")

        setup.model.draft = ""
        #expect(setup.model.suggestion == "add subtract to calc.py")
    }

    @Test("同一段完成期間只讀一次畫面(指令預算)")
    func readsOncePerCompletion() async throws {
        let setup = try await Self.withSuggestion()
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "done"))
        await Self.trap(setup)

        await setup.model.poll()

        #expect(setup.model.suggestion == "add subtract to calc.py")
        #expect(await Self.ansiReads(setup) == 1)
        #expect(await setup.host.bridge.unmetExpectations.count == 1)
    }

    @Test("離開完成就拿掉建議;再次完成時重讀，而且從工作中轉完成的這次輪詢只讀一次畫面(背景 agents 窗格共用，R-F02)")
    func rereadsAfterWorking() async throws {
        let setup = try await Self.withSuggestion()
        // 主機上接受建議並送出：Agent 開始工作，建議消失。
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "working"))
        await setup.host.bridge.expect(Self.bridge, reply: PaneScreens.read("claude-idle"))
        await setup.model.poll()
        #expect(setup.model.suggestion == nil)

        // 又完成，這次的畫面有另一句建議(錄製的建議畫面)。
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "done"))
        await setup.host.bridge.expect(Self.bridge, reply: Self.ansiScreen("suggestion"))
        await Self.trap(setup)
        await setup.model.poll()

        #expect(setup.model.suggestion == "add subtract to calc.py")
        #expect(await Self.ansiReads(setup) == 2)
        #expect(await ConversationAnswerTests.paneReads(setup) == 3)
        #expect(await setup.host.bridge.unmetExpectations.count == 1)
    }

    @Test("從手機送出：建議立刻拿掉，下次輪詢重讀(herdr 可能來不及回報工作中)")
    func sendClearsAndRereads() async throws {
        let setup = try await Self.withSuggestion()
        #expect(setup.model.acceptSuggestion())
        await ConversationSlashPanelTests.expectSlashSend(setup)

        await setup.model.send()

        #expect(setup.model.suggestion == nil)
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "done"))
        await setup.host.bridge.expect(Self.bridge, reply: Self.ansiScreen("no-suggestion"))
        await setup.model.poll()
        #expect(await Self.ansiReads(setup) == 2)
        #expect(setup.model.suggestion == nil)
    }

    // MARK: - code review(#124)

    @Test("閒置(herdr 已把完成標成看過)也是等下一步：讀含 ANSI 的畫面、顯示建議(#121 故事 5)")
    func idleClaudeShowsSuggestion() async throws {
        let setup = try ConversationAnswerTests.setup()
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "idle"))
        await setup.host.bridge.expect(Self.bridge, reply: Self.ansiScreen("suggestion"))

        await setup.model.poll()

        #expect(setup.model.suggestion == "add subtract to calc.py")
        #expect(await Self.ansiReads(setup) == 1)
    }

    @Test("完成轉閒置不算新的一段：已讀到建議就不重讀，建議保留")
    func doneToIdleKeepsSuggestion() async throws {
        let setup = try await Self.withSuggestion()
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "idle"))
        await Self.trap(setup)

        await setup.model.poll()

        #expect(setup.model.suggestion == "add subtract to calc.py")
        #expect(await Self.ansiReads(setup) == 1)
    }

    @Test("讀畫面時從手機送出：舊的讀取回來後不把舊建議寫回，下次輪詢重讀")
    func sendDuringReadDiscardsStaleSuggestion() async throws {
        let setup = try ConversationAnswerTests.setup()
        // 先有一次完整的輪詢(工作中),聊天才可以送出。
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "working"))
        await setup.host.bridge.expect(Self.bridge, reply: PaneScreens.read("claude-idle"))
        await setup.model.poll()
        // 完成：畫面讀取(第 4 次執行)先不回應，等送出完成後才回。
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "done"))
        await setup.host.bridge.expect(Self.bridge, reply: FakeReply(keepsOpen: true))
        let polling = Task { await setup.model.poll() }
        #expect(await setup.host.bridge.waitForExecutions(4) == 4)

        setup.model.draft = "hello"
        await ConversationSlashPanelTests.expectSlashSend(setup)
        await setup.model.send()
        #expect(setup.model.draft.isEmpty)
        await setup.host.bridge.send(stdout: Fixtures.data("pane.read.ansi.suggestion.ndjson"), toExecution: 3)
        await polling.value

        #expect(setup.model.suggestion == nil)
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "done"))
        await setup.host.bridge.expect(Self.bridge, reply: Self.ansiScreen("suggestion"))
        await setup.model.poll()
        #expect(setup.model.suggestion == "add subtract to calc.py")
    }

    @Test("Claude 還沒產生建議：同一段完成期間之後的輪詢再讀，讀到就停")
    func rereadsUntilSuggestionAppears() async throws {
        let setup = try ConversationAnswerTests.setup()
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "done"))
        await setup.host.bridge.expect(Self.bridge, reply: Self.ansiScreen("no-suggestion"))
        await setup.model.poll()
        #expect(setup.model.suggestion == nil)

        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "done"))
        await setup.host.bridge.expect(Self.bridge, reply: Self.ansiScreen("suggestion"))
        await setup.model.poll()
        #expect(setup.model.suggestion == "add subtract to calc.py")

        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "done"))
        await Self.trap(setup)
        await setup.model.poll()
        #expect(await Self.ansiReads(setup) == 2)
        #expect(await setup.host.bridge.unmetExpectations.count == 1)
    }

    @Test("一直沒有建議：同一段完成期間最多讀 3 次畫面(指令預算 R-F01)")
    func rereadsAreBounded() async throws {
        let setup = try ConversationAnswerTests.setup()
        for _ in 0..<3 {
            await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "done"))
            await setup.host.bridge.expect(Self.bridge, reply: Self.ansiScreen("no-suggestion"))
            await setup.model.poll()
        }
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "done"))
        await Self.trap(setup)
        await setup.model.poll()

        #expect(setup.model.suggestion == nil)
        #expect(await Self.ansiReads(setup) == 3)
        #expect(await setup.host.bridge.unmetExpectations.count == 1)
    }

    @Test("連不上主機：拿掉建議;恢復後重讀")
    func offlineClearsSuggestion() async throws {
        let setup = try await Self.withSuggestion()
        await setup.host.bridge.expect(Self.bridge, reply: FakeReply(stderr: Data("ssh: connect to host timed out".utf8), exitCode: 255))
        await setup.model.poll()
        #expect(setup.model.isOffline)
        #expect(setup.model.suggestion == nil)

        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "done"))
        await setup.host.bridge.expect(Self.bridge, reply: Self.ansiScreen("suggestion"))
        await setup.model.poll()
        #expect(setup.model.suggestion == "add subtract to calc.py")
    }

    /// 以錄製的 snapshot 為底，把這個 Pane 的 id 換掉(= Agent 不在了)。
    @Test("Agent 不在了：拿掉建議")
    func agentGoneClearsSuggestion() async throws {
        let setup = try await Self.withSuggestion()
        await setup.host.bridge.expect(Self.bridge, reply: ConversationModelTests.snapshot { $0["pane_id"] = "w1:p99" })
        await setup.model.poll()

        #expect(setup.model.suggestion == nil)
    }

    @Test("面板剛關掉的這次輪詢：同一次讀畫面就判定面板與建議，建議立刻出現")
    func suggestionAfterPanelClosesUsesThisPoll() async throws {
        let setup = try await ConversationSlashPanelTests.panelOpen()
        #expect(setup.model.panel != nil)
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "idle"))
        await setup.host.bridge.expect(Self.bridge, reply: Self.ansiScreen("suggestion"))
        await setup.model.poll()

        #expect(setup.model.panel == nil)
        #expect(setup.model.suggestion == "add subtract to calc.py")
    }
}
