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

    static func opened(kind: String = "claude", status: String = "idle") async throws -> ConversationAnswerTests.Setup {
        let setup = try ConversationAnswerTests.setup(sleeper: RecordingSleeper { $0 == .milliseconds(300) })
        await setup.host.bridge.expect(bridge, reply: ConversationAnswerTests.snapshot(status: status, kind: kind))
        await setup.model.poll()
        return setup
    }

    /// 開始選模型：新鮮 snapshot、`agent.prompt`,之後輪詢讀到面板。
    static func panelOpen() async throws -> ConversationAnswerTests.Setup {
        let setup = try await opened()
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
