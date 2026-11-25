import Foundation
import Testing

/// slash 面板「輸入框變成面板」的原始碼守門(#624、spec #612):面板用系統控制項、不自畫選項列與動作鈕;
/// 窄視窗取代輸入框(不是 sheet),寬視窗才 sheet;X／✓ 共用元件樣式。prior art:`ChevronPushUsageTests`。
@Suite("slash 面板用法")
struct SlashPanelUsageTests {
    private static let featuresFolder = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "src/PurrdrFeatures")

    private static func source(_ name: String) throws -> String {
        try String(contentsOf: featuresFolder.appending(path: name), encoding: .utf8)
    }

    @Test("選項與層級是系統 Picker(.inline),調整是 Stepper;不自畫選項列、不用 .plain 按鈕")
    func usesSystemControls() throws {
        let panel = try Self.source("SlashPanelCard.swift")
        #expect(panel.contains("pickerStyle(.inline)"))
        #expect(panel.contains("Stepper"))
        #expect(!panel.contains(".buttonStyle(.plain)"), "不自畫選項列")
        #expect(!panel.contains("AppSurface.card"), "不自繪卡片底")
        #expect(!panel.contains("presentationBackground"), "不蓋 sheet 的系統玻璃")
    }

    @Test("窄視窗面板取代輸入框:ComposerBar 以 SlashPanelBar 換掉 composer,高度同鍵盤")
    func panelReplacesComposer() throws {
        let composer = try Self.source("ComposerView.swift")
        #expect(composer.contains("SlashPanelBar(model: model, panel: panel, height: keyboardHeight)"))
        #expect(composer.contains("keyboardWillChangeFrameNotification"), "要記住最近一次鍵盤高度")
        let panel = try Self.source("SlashPanelCard.swift")
        #expect(panel.contains(".frame(height: height)"))
    }

    @Test("寬視窗才用 sheet;sheet 內左上 X、右上 ✓ 用共用的 modal 工具列")
    func sheetOnlyOnRegularWidth() throws {
        let panel = try Self.source("SlashPanelCard.swift")
        #expect(panel.contains("== .sheet"))
        #expect(panel.contains("SheetCloseToolbar(identifier: \"panel.cancel\""))
        #expect(panel.contains("ModalConfirmToolbar("))
        let conversation = try Self.source("ConversationView.swift")
        #expect(conversation.contains(".slashPanelSheet(model: model)"))
    }

    @Test("輸入框位置的 ✓ 用 prominent 填色樣式、X 是系統玻璃圓鈕")
    func headerButtonsAreSystemStyles() throws {
        let panel = try Self.source("SlashPanelCard.swift")
        #expect(panel.contains("filledProminentButtonStyle()"))
        #expect(panel.contains(".buttonStyle(.glass)"))
        #expect(panel.contains("\"xmark\""))
    }
}
