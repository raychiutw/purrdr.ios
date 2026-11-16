import Foundation
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// Slash 進階(#45):點選行為(直接送出／只填入／參數提示)與 slash 面板卡片(行為規格 F9.3、F9.4、R-C04、R-C05)。
/// herdr 走假主機;面板畫面是依規格手寫的(`PaneScreens`),`agent.prompt`、`pane.send_keys` 的回應不錄。
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

    @Test("點選不需參數的指令：直接送出 `/名稱`,輸入框清空")
    func pickWithoutArgumentsSends() async throws {
        let setup = try await Self.opened()
        await Self.expectSlashSend(setup)
        setup.model.draft = "/cont"

        await setup.model.pick(slash: SlashCommand(name: "context", summary: "Show context usage"))

        let prompts = await Self.promptRequests(setup)
        #expect(prompts.count == 1)
        #expect(prompts.first?.contains(#""text":"\/context""#) == true || prompts.first?.contains(#""text":"/context""#) == true)
        #expect(setup.model.draft.isEmpty)
    }

    @Test("點選有副作用的指令(/compact):只填入 `/compact `,不送出;選填參數照樣淡淡提示")
    func pickSideEffectOnlyFills() async throws {
        let setup = try await Self.opened()
        setup.model.draft = "/comp"

        await setup.model.pick(slash: SlashCommand(name: "compact", argumentHint: "[instructions]", summary: "Compact the conversation"))

        #expect(setup.model.draft == "/compact ")
        #expect(await Self.promptRequests(setup).isEmpty)
        #expect(setup.model.slashArgumentHint == "[instructions]")
    }

    @Test("點選需要參數的指令：填入 `/名稱 ` 並在游標後提示;開始打參數就不再提示")
    func pickRequiredArgumentShowsHint() async throws {
        let setup = try await Self.opened()
        setup.model.draft = "/add"

        await setup.model.pick(slash: SlashCommand(name: "add-dir", argumentHint: "<path>", summary: "Add a working directory"))

        #expect(setup.model.draft == "/add-dir ")
        #expect(setup.model.slashArgumentHint == "<path>")
        #expect(await Self.promptRequests(setup).isEmpty)
        setup.model.draft = "/add-dir ~/src"
        #expect(setup.model.slashArgumentHint == nil)
    }

    // MARK: - 面板

    /// 送出 `/model` 後讀畫面看到面板。
    static func panelOpen(sleeper: RecordingSleeper = RecordingSleeper()) async throws -> ConversationAnswerTests.Setup {
        let setup = try await Self.opened(sleeper: sleeper)
        await Self.expectSlashSend(setup)
        await setup.model.pick(slash: SlashCommand(name: "model", argumentHint: "[model]", summary: "Choose the model"))
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
        #expect(panel.options.first { $0.isCurrent }?.label == "Sonnet")
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
