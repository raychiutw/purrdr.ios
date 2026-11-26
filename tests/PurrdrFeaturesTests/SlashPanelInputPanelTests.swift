import Foundation
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// slash 面板「輸入框變成面板」(#624、spec #612 原型 C)的邏輯:在哪裡呈現、✓ 與 X 對應的按鍵。
/// 送鍵序列規則(`s` 而非 Enter、永不送數字)由 `ConversationSlashPanelTests` 與 `ConversationModelChoiceTests` 守住;
/// 這裡確認新的左 X／右 ✓ 沿用同一條路徑、沒有另開送鍵。
@MainActor
@Suite("slash 面板輸入框位置")
struct SlashPanelInputPanelTests {
    @Test(
        "窄視窗與寬視窗都取代輸入框、沒有面板或模型膠囊的 sheet 開著時不呈現",
        arguments: [
            (true, false, SlashPanelPresentation.inline),
            (false, false, SlashPanelPresentation.none),
            (true, true, SlashPanelPresentation.none),
            (false, true, SlashPanelPresentation.none),
        ]
    )
    func presentation(hasPanel: Bool, isChoosingModel: Bool, expected: SlashPanelPresentation) {
        #expect(SlashPanelPresentation.resolve(hasPanel: hasPanel, isChoosingModel: isChoosingModel) == expected)
    }

    @Test("右 ✓ 送面板提示行的 Enter,不送 `s`,也不送數字")
    func confirmSendsEnter() async throws {
        let setup = try await ConversationSlashPanelTests.panelOpen()
        let panel = try #require(setup.model.panel)
        let controls = SlashPanelControls(model: setup.model, panel: panel)
        #expect(controls.hasConfirm)
        await setup.host.bridge.expect(ConversationSlashPanelTests.bridge, reply: PromptReplies.keysAccepted)

        let sent = await controls.confirm()

        #expect(sent)
        let keys = await ConversationAnswerTests.keyRequests(setup)
        #expect(keys == [ConversationAnswerTests.keys(["enter"])])
    }

    @Test("左 X 送 Esc 取消,不改設定")
    func cancelSendsEscape() async throws {
        let setup = try await ConversationSlashPanelTests.panelOpen()
        let panel = try #require(setup.model.panel)
        await setup.host.bridge.expect(ConversationSlashPanelTests.bridge, reply: PromptReplies.keysAccepted)

        await SlashPanelControls(model: setup.model, panel: panel).cancel()

        let keys = await ConversationAnswerTests.keyRequests(setup)
        #expect(keys == [ConversationAnswerTests.keys(["esc"])])
    }

    @Test("面板沒有 Enter 動作(只有關閉)時沒有 ✓,confirm 什麼都不送")
    func noConfirmWithoutEnter() async throws {
        let setup = try await ConversationSlashPanelTests.panelOpen()
        var panel = try #require(setup.model.panel)
        panel.actions = [SlashPanelAction(key: "esc", label: "close")]
        let controls = SlashPanelControls(model: setup.model, panel: panel)

        #expect(!controls.hasConfirm)
        #expect(await controls.confirm() == false)
        #expect(await ConversationAnswerTests.keyRequests(setup).isEmpty)
    }
}
