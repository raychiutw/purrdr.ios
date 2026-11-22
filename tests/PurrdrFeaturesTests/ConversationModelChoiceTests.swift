import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 輸入框的模型膠囊(#350):顯示目前模型,點開後送 `/model`、讀面板、用勾選列選定;
/// 沿用既有的 slash 面板能力,永不送數字。**不對任何真實 agent 送 slash 指令或按鍵。**
@MainActor
@Suite("輸入框的模型膠囊")
struct ConversationModelChoiceTests {
    static let bridge = HerdrCommand.bridge()

    static func opened(
        kind: String = "claude", status: String = "idle", sleeper: RecordingSleeper = RecordingSleeper { $0 == .milliseconds(300) }
    ) async throws -> ConversationAnswerTests.Setup {
        let setup = try ConversationAnswerTests.setup(sleeper: sleeper)
        await setup.host.bridge.expect(bridge, reply: ConversationAnswerTests.snapshot(status: status, kind: kind))
        await setup.model.poll()
        return setup
    }

    /// 開始選模型：新鮮 snapshot、`agent.prompt`,之後輪詢讀到面板。
    static func panelOpen(sleeper: RecordingSleeper = RecordingSleeper { $0 == .milliseconds(300) }) async throws -> ConversationAnswerTests.Setup {
        let setup = try await opened(sleeper: sleeper)
        await ConversationSlashPanelTests.expectSlashSend(setup)
        await setup.model.beginChoosingModel()
        await setup.host.bridge.expect(bridge, reply: ConversationSlashPanelTests.idle())
        await setup.host.bridge.expect(bridge, reply: PaneScreens.read("claude-panel-model"))
        await setup.model.poll()
        return setup
    }

    @Test("膠囊顯示對話紀錄裡目前的模型名稱")
    func showsCurrentModelName() async throws {
        let setup = try await Self.opened()
        #expect(setup.model.modelName != nil)
        #expect(setup.model.modelName == setup.model.metadata.model.map(TranscriptMetadata.displayName(ofModel:)))
    }

    @Test("只有 Claude 在閒置時能選模型;工作中、其他 Agent 都不行")
    func availability() async throws {
        #expect(try await Self.opened().model.canChooseModel)
        #expect(try await Self.opened(status: "working").model.canChooseModel == false)
        #expect(try await Self.opened(kind: "codex").model.canChooseModel == false)
    }

    @Test("開始選模型:送 `/model`、不產生回音泡泡,讀到面板後可選項目與目前打勾")
    func beginSendsModelCommandWithoutEcho() async throws {
        let setup = try await Self.panelOpen()

        let prompts = await ConversationSlashPanelTests.promptRequests(setup)
        #expect(prompts.count == 1)
        #expect(prompts[0].contains(#""text":"/model""#))
        #expect(setup.model.isChoosingModel)
        #expect(setup.model.echoes.isEmpty)
        #expect(setup.model.panel?.options.first { $0.isCurrent }?.label == "Opus 5.5")
    }

    @Test("選定:點選項送方向鍵、再送「只用在這個 session」的 s(不是設為預設的 Enter),永不送數字;完成後 sheet 狀態結束")
    func chooseSendsArrowsThenEnter() async throws {
        let setup = try await Self.panelOpen()
        let panel = try #require(setup.model.panel)
        await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.keysAccepted)
        await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.keysAccepted)

        await setup.model.chooseModel(panel.options[2])

        let keys = await ConversationAnswerTests.keyRequests(setup)
        #expect(keys == [ConversationAnswerTests.keys(["down"]), ConversationAnswerTests.keys(["s"])])
        #expect(!setup.model.isChoosingModel)
    }

    @Test("不選就關掉:面板還開著就送 Esc;面板沒出現就不送按鍵")
    func dismissCancelsPanel() async throws {
        let setup = try await Self.panelOpen()
        await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.keysAccepted)

        await setup.model.finishChoosingModel()

        #expect(await ConversationAnswerTests.keyRequests(setup) == [ConversationAnswerTests.keys(["esc"])])
        #expect(!setup.model.isChoosingModel)

        let bare = try await Self.opened()
        await ConversationSlashPanelTests.expectSlashSend(bare)
        await bare.model.beginChoosingModel()
        await bare.model.finishChoosingModel()
        #expect(await ConversationAnswerTests.keyRequests(bare).isEmpty)
    }
}

/// 模型選擇 sheet 的投入程度子頁與降級(#384)。這些測試用不自動觸發的 sleeper(輪詢由測試自己推進)。
@MainActor
@Suite("模型選擇 sheet:投入程度、Ultracode、降級與膠囊狀態")
struct ConversationEffortSheetTests {
    static let bridge = ConversationModelChoiceTests.bridge

    static func panelOpen() async throws -> ConversationAnswerTests.Setup {
        try await ConversationModelChoiceTests.panelOpen(sleeper: RecordingSleeper())
    }

    /// 進入投入程度子頁:Esc 收掉 `/model` 面板、送 `/effort`,輪詢讀到滑桿面板。
    static func effortOpen(screen: String = "claude-panel-effort") async throws -> ConversationAnswerTests.Setup {
        let setup = try await panelOpen()
        await setup.host.bridge.expect(bridge, reply: PromptReplies.keysAccepted)
        await ConversationSlashPanelTests.expectSlashSend(setup)
        await setup.model.openEffortPage()
        await setup.host.bridge.expect(bridge, reply: ConversationSlashPanelTests.idle())
        await setup.host.bridge.expect(bridge, reply: PaneScreens.read(screen))
        await setup.model.poll()
        return setup
    }

    @Test("進入投入程度:先 Esc 收掉 /model 面板(不改模型),再送 /effort;讀到滑桿後子頁有層級與目前值")
    func openEffortPageSendsEscThenEffort() async throws {
        let setup = try await Self.effortOpen()

        #expect(await ConversationAnswerTests.keyRequests(setup) == [ConversationAnswerTests.keys(["esc"])])
        let prompts = await ConversationSlashPanelTests.promptRequests(setup)
        #expect(prompts.count == 2 && prompts[1].contains(#""text":"/effort""#))
        #expect(setup.model.modelSheetPage == .effort)
        #expect(setup.model.effortSlider == SlashPanelSlider(levels: ["low", "medium", "high", "xhigh", "max"], current: 1))
    }

    @Test("點層級只移動滑桿(送 right × 差距,永不送數字),還沒確認")
    func chooseLevelOnlyMovesCursor() async throws {
        let setup = try await Self.effortOpen()
        await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.keysAccepted)

        await setup.model.chooseEffortLevel(3)

        let keys = await ConversationAnswerTests.keyRequests(setup)
        #expect(keys.last == ConversationAnswerTests.keys(["right", "right"]))
        #expect(keys.count == 2, "只有 Esc 與移動,沒有 Enter")
    }

    @Test("離開子頁:層級有變就按 Enter 確認(成為新 session 的預設);沒變按 Esc;之後重開 /model 回到模型列")
    func leavingConfirmsOnlyWhenChanged() async throws {
        let changed = try await Self.effortOpen()
        await changed.host.bridge.expect(Self.bridge, reply: PromptReplies.keysAccepted)
        await changed.model.chooseEffortLevel(3)
        // 面板跟著移動後的畫面(▲ 在 xhigh)。
        let moved = PaneScreens.text("claude-panel-effort").replacingOccurrences(
            of: "──────────▲───────────────────────────────", with: "──────────────────────────▲───────────────────────")
        await changed.host.bridge.expect(Self.bridge, reply: ConversationSlashPanelTests.idle())
        await changed.host.bridge.expect(Self.bridge, reply: PaneScreens.read(text: moved))
        await changed.model.poll()
        #expect(changed.model.effortSlider?.current == 3)

        await changed.host.bridge.expect(Self.bridge, reply: PromptReplies.keysAccepted)
        await ConversationSlashPanelTests.expectSlashSend(changed)
        await changed.model.closeEffortPage()
        let keys = await ConversationAnswerTests.keyRequests(changed)
        #expect(keys.last == ConversationAnswerTests.keys(["enter"]))
        #expect(changed.model.modelSheetPage == .models)
        let prompts = await ConversationSlashPanelTests.promptRequests(changed)
        #expect(prompts.last?.contains(#""text":"/model""#) == true)

        let untouched = try await Self.effortOpen()
        await untouched.host.bridge.expect(Self.bridge, reply: PromptReplies.keysAccepted)
        await ConversationSlashPanelTests.expectSlashSend(untouched)
        await untouched.model.closeEffortPage()
        #expect(await ConversationAnswerTests.keyRequests(untouched).last == ConversationAnswerTests.keys(["esc"]))
    }

    @Test("Ultracode:面板有開關且層級含 xhigh 才出現;切換送 Tab;沒有開關或不支援 xhigh 就不出現、不送")
    func ultracodeCondition() async throws {
        let setup = try await Self.effortOpen()
        #expect(setup.model.showsUltracode)
        #expect(setup.model.ultracodeIsOn == false)
        await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.keysAccepted)
        await setup.model.toggleUltracode()
        #expect(await ConversationAnswerTests.keyRequests(setup).last == ConversationAnswerTests.keys(["tab"]))

        let noXhigh = PaneScreens.text("claude-panel-effort").replacingOccurrences(of: "xhigh", with: "ultra")
        let unsupported = try await Self.effortOpen(screen: "claude-panel-effort")
        await unsupported.host.bridge.expect(Self.bridge, reply: ConversationSlashPanelTests.idle())
        await unsupported.host.bridge.expect(Self.bridge, reply: PaneScreens.read(text: noXhigh))
        await unsupported.model.poll()
        #expect(!unsupported.model.showsUltracode)

        let noSwitch = PaneScreens.text("claude-panel-effort").replacingOccurrences(of: "Ultracode  off", with: "              ")
        let missing = try await Self.effortOpen(screen: "claude-panel-effort")
        await missing.host.bridge.expect(Self.bridge, reply: ConversationSlashPanelTests.idle())
        await missing.host.bridge.expect(Self.bridge, reply: PaneScreens.read(text: noSwitch))
        await missing.model.poll()
        #expect(!missing.model.showsUltracode)
    }

    @Test("面板讀不到:監看期滿後標成讀不到,sheet 只顯示目前模型、不開自己的選單")
    func unreadablePanelDegrades() async throws {
        let setup = try await ConversationModelChoiceTests.opened(sleeper: RecordingSleeper())
        await ConversationSlashPanelTests.expectSlashSend(setup)
        await setup.model.beginChoosingModel()
        #expect(setup.model.isChoosingModel)
        #expect(!setup.model.modelPanelUnreadable, "監看期內還在讀")

        setup.clock.advance(by: 9)
        await setup.host.bridge.expect(Self.bridge, reply: ConversationSlashPanelTests.idle())
        await setup.model.poll()

        #expect(setup.model.modelPanelUnreadable)
        #expect(setup.model.panel == nil)
        #expect(setup.model.modelName != nil, "仍顯示目前模型")
    }

    @Test("膠囊停用原因:等你回覆、工作中、唯讀;可選時沒有原因")
    func capsuleLock() async throws {
        #expect(try await ConversationModelChoiceTests.opened().model.modelChoiceLock == nil)
        #expect(try await ConversationModelChoiceTests.opened(status: "blocked").model.modelChoiceLock == .waitingForYou)
        #expect(try await ConversationModelChoiceTests.opened(status: "working").model.modelChoiceLock == .working)
    }

    @Test("Codex:膠囊顯示目前模型但不能在 app 內切換,有說明")
    func codexShowsButCannotSwitch() async throws {
        let setup = try await ConversationModelChoiceTests.opened(kind: "codex")
        #expect(setup.model.showsModelCapsule == (setup.model.modelName != nil))
        #expect(!setup.model.canChooseModel)
        #expect(setup.model.modelChoiceLock == .unsupportedAgent)
    }

    @Test("切換失敗(按鍵送不出去):不改模型、結束切換中,輸入列上方說明")
    func switchFailureRestores() async throws {
        let setup = try await ConversationModelChoiceTests.panelOpen(sleeper: RecordingSleeper())
        let panel = try #require(setup.model.panel)
        await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.error("pane_not_found", "gone"))

        await setup.model.chooseModel(panel.options[2])

        #expect(setup.model.notice == .modelSwitchFailed)
        #expect(!setup.model.isSwitchingModel)
        #expect(!setup.model.isChoosingModel)
        #expect(await ConversationAnswerTests.keyRequests(setup).count == 1, "失敗後不再送確認鍵")
    }
}
