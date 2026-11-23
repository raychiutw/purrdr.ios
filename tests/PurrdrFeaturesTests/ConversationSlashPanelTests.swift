import Foundation
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// Slash 進階(#45、#83):點選行為(一律只填入／參數提示)與 slash 面板卡片(行為規格 F9.3、F9.4、R-C04)。
/// herdr 走假主機;Claude `/model` 面板畫面是真實錄製(#65,`PaneScreens`),`agent.prompt`、`pane.send_keys` 的回應不錄。
/// **不對任何真實 agent 送 slash 指令或按鍵。**
@MainActor
@Suite("Slash 點選與面板")
struct ConversationSlashPanelTests {
    static let bridge = HerdrCommand.bridge()

    static func idle() -> FakeReply { ConversationAnswerTests.snapshot(status: "idle") }

    static func opened(sleeper: RecordingSleeper = RecordingSleeper()) async throws -> ConversationAnswerTests.Setup {
        let setup = try ConversationAnswerTests.setup(sleeper: sleeper)
        await setup.host.bridge.expect(bridge, reply: idle())
        await setup.model.poll()
        return setup
    }

    static func promptRequests(_ setup: ConversationAnswerTests.Setup) async -> [String] {
        await setup.host.bridge.executions.map(\.stdinText).filter { $0.contains(#""method":"agent.prompt""#) }
    }

    /// 送出 slash 指令：新鮮 snapshot + `agent.prompt`。
    static func expectSlashSend(_ setup: ConversationAnswerTests.Setup) async {
        await setup.host.bridge.expect(bridge, reply: idle())
        await setup.host.bridge.expect(bridge, reply: PromptReplies.prompted())
    }

    // MARK: - 點選行為

    @Test(
        "點選任何指令都只填入 `/名稱 `,不送出任何主機指令;有參數提示照樣提示(#83)",
        arguments: [
            SlashCommand(name: "context", summary: "Show context usage"),
            SlashCommand(name: "model", argumentHint: "[model]", summary: "Choose the model"),
            SlashCommand(name: "review", summary: "Review a pull request"),
            SlashCommand(name: "demo-kit:changelog", summary: "Summarize recent changes"),
        ]
    )
    func pickOnlyFills(command: SlashCommand) async throws {
        let setup = try await Self.opened()
        // 備好送出的回應：真的送出就會被用掉。
        await Self.expectSlashSend(setup)
        let executionsBefore = await setup.host.bridge.executions.count
        setup.model.draft = "/" + String(command.name.prefix(3))

        setup.model.pick(slash: command)

        #expect(setup.model.draft == "/\(command.name) ")
        #expect(setup.model.slashArgumentHint == command.argumentHint)
        #expect(await setup.host.bridge.executions.count == executionsBefore)
        #expect(await setup.host.bridge.unmetExpectations.count == 2)
    }

    @Test("選單選用的指令進入文中上色的已知名稱，送出後仍在(#469)")
    func pickedNamesStayKnown() async throws {
        let setup = try await Self.opened()
        #expect(setup.model.inlineSlashNames.isEmpty)
        setup.model.draft = "先 /gri"
        setup.model.pick(slash: SlashCommand(name: "grill", summary: "Grill me"))
        #expect(setup.model.draft == "先 /grill ")
        #expect(setup.model.inlineSlashNames == ["grill"])
        setup.model.draft = ""
        #expect(setup.model.inlineSlashNames == ["grill"])
    }

    @Test("在 slash 選單按 Return 選定 `/model`:只填入 `/model `,不送出(#83)")
    func returnInMenuOnlyFills() async throws {
        let setup = try await Self.opened()
        setup.model.draft = "/model"
        await setup.model.slash.load()
        let executionsBefore = await setup.host.bridge.executions.count

        #expect(setup.model.slash.handle(.select))

        #expect(setup.model.draft == "/model ")
        #expect(setup.model.slashArgumentHint == "[model]")
        #expect(await setup.host.bridge.executions.count == executionsBefore)
    }

    @Test("點選有副作用的指令(/compact):只填入 `/compact `,不送出;選填參數照樣淡淡提示")
    func pickSideEffectOnlyFills() async throws {
        let setup = try await Self.opened()
        setup.model.draft = "/comp"

        setup.model.pick(slash: SlashCommand(name: "compact", argumentHint: "[instructions]", summary: "Compact the conversation"))

        #expect(setup.model.draft == "/compact ")
        #expect(await Self.promptRequests(setup).isEmpty)
        #expect(setup.model.slashArgumentHint == "[instructions]")
    }

    @Test("點選需要參數的指令：填入 `/名稱 ` 並在游標後提示;開始打參數就不再提示")
    func pickRequiredArgumentShowsHint() async throws {
        let setup = try await Self.opened()
        setup.model.draft = "/add"

        setup.model.pick(slash: SlashCommand(name: "add-dir", argumentHint: "<path>", summary: "Add a working directory"))

        #expect(setup.model.draft == "/add-dir ")
        #expect(setup.model.slashArgumentHint == "<path>")
        #expect(await Self.promptRequests(setup).isEmpty)
        setup.model.draft = "/add-dir ~/src"
        #expect(setup.model.slashArgumentHint == nil)
    }

    @Test("文字中間選定需要參數的 skill:游標後提示參數;開始打參數就不再提示(#230)")
    func inlinePickShowsArgumentHint() async throws {
        let setup = try await Self.opened()
        let draft = "請 /ad 這裡"
        setup.model.updateDraftCaret(5, in: draft)
        setup.model.draft = draft

        setup.model.pick(slash: SlashCommand(name: "add-dir", argumentHint: "<path>", summary: "Add a working directory"))

        #expect(setup.model.draft == "請 /add-dir 這裡")
        #expect(setup.model.draftCaret == 11)
        #expect(setup.model.slashArgumentHint == "<path>")
        #expect(await Self.promptRequests(setup).isEmpty)
        setup.model.draft = "請 /add-dir ~ 這裡"
        #expect(setup.model.slashArgumentHint == nil)
    }

    // MARK: - 面板

    /// 點選 `/model`、使用者按送出後讀畫面看到面板。
    static func panelOpen(sleeper: RecordingSleeper = RecordingSleeper()) async throws -> ConversationAnswerTests.Setup {
        let setup = try await Self.opened(sleeper: sleeper)
        await Self.expectSlashSend(setup)
        setup.model.pick(slash: SlashCommand(name: "model", argumentHint: "[model]", summary: "Choose the model"))
        await setup.model.send()
        await setup.host.bridge.expect(bridge, reply: idle())
        await setup.host.bridge.expect(bridge, reply: PaneScreens.read("claude-panel-model"))
        await setup.model.poll()
        return setup
    }

    @Test("送出 slash 指令後主動讀畫面(herdr 仍回報 idle),看到面板就顯示卡片")
    func slashSendWatchesForPanel() async throws {
        let setup = try await Self.panelOpen()

        let panel = try #require(setup.model.panel)
        #expect(panel.title == "Select model")
        #expect(panel.options.first { $0.isCurrent }?.label == "Opus 5.5")
        #expect(await ConversationAnswerTests.paneReads(setup) == 1)
    }

    @Test("閒置、沒有送過 slash 指令時不讀畫面(指令預算)")
    func idleWithoutSlashDoesNotRead() async throws {
        let setup = try await Self.opened()
        await setup.host.bridge.expect(Self.bridge, reply: Self.idle())
        await setup.model.poll()
        #expect(setup.model.panel == nil)
        #expect(await ConversationAnswerTests.paneReads(setup) == 0)
    }

    @Test("點選項送方向鍵移動游標，永不送數字;動作鈕送面板自己的鍵")
    func panelSendsArrowsNeverDigits() async throws {
        let setup = try await Self.panelOpen()
        let panel = try #require(setup.model.panel)
        await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.keysAccepted)
        await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.keysAccepted)

        await setup.model.operatePanel(.select(panel.options[2]))
        await setup.model.operatePanel(.action(try #require(panel.actions.first { $0.key == "enter" })))

        let keys = await ConversationAnswerTests.keyRequests(setup)
        #expect(keys == [ConversationAnswerTests.keys(["down"]), ConversationAnswerTests.keys(["enter"])])
        #expect(!keys.contains { $0.contains(/"keys":\[[^\]]*"\d"/) })
    }

    @Test("面板操作後 0.3 秒重讀;畫面上面板不見了就關掉卡片，監看結束後不再讀畫面")
    func panelClosesWhenGone() async throws {
        let sleeper = RecordingSleeper { $0 == .milliseconds(300) }
        let setup = try await Self.panelOpen(sleeper: sleeper)
        await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.keysAccepted)
        await setup.host.bridge.expect(Self.bridge, reply: Self.idle())
        await setup.host.bridge.expect(Self.bridge, reply: PaneScreens.read("claude-idle"))

        await setup.model.operatePanel(.action(try #require(setup.model.panel?.actions.first { $0.key == "esc" })))
        try await waitUntil { await ConversationAnswerTests.paneReads(setup) == 2 }
        try await waitUntil { await MainActor.run { setup.model.panel == nil } }

        setup.clock.advance(by: 9)
        await setup.host.bridge.expect(Self.bridge, reply: Self.idle())
        await setup.model.poll()
        #expect(await ConversationAnswerTests.paneReads(setup) == 2)
    }

    @Test("agent 開始工作就關掉面板卡片")
    func panelClosesWhenWorking() async throws {
        let setup = try await Self.panelOpen()
        await setup.host.bridge.expect(Self.bridge, reply: ConversationAnswerTests.snapshot(status: "working"))
        await setup.host.bridge.expect(Self.bridge, reply: PaneScreens.read("claude-idle"))
        await setup.model.poll()
        #expect(setup.model.panel == nil)
    }
}
