import Foundation
import Testing

/// 聊天頂列右上只剩〔用量環｜⋯〕(#617,spec #612):原始碼守門。
@Suite("聊天頂列用法")
struct ChatToolbarUsageTests {
    static let toolbarFiles = ["ConversationUsageViews.swift", "ConversationMoreMenu.swift", "ConversationPanel.swift"]

    @Test("工具列項目不自加 44pt 最小寬高,交給系統排版")
    func toolbarItemsDoNotForceSize() throws {
        for name in Self.toolbarFiles {
            let text = try GlassLevelUsageTests.source(name)
            #expect(!text.contains("minWidth: 44"), "\(name) 的工具列項目不要自加 44pt 寬度")
            #expect(!text.contains("minHeight: 44"), "\(name) 的工具列項目不要自加 44pt 高度")
            #expect(!text.contains("circleDiameter"), "\(name) 不要用自繪頂列的尺寸常數")
        }
    }

    @Test("聊天標題是系統工具列的玻璃膠囊(principal＋共用 floatingGlass),不自畫膠囊、狀態點與權限盾牌")
    func titleIsSystemGlassCapsule() throws {
        // 使用者 2026-11-26 改決定(推翻 #618 的純系統標題):標題要膠囊風格,只有外觀、不能點。
        let title = try GlassLevelUsageTests.source("ConversationListContentBuilder.swift")
        #expect(title.contains("placement: .principal"), "標題放在工具列 principal")
        #expect(title.contains(".floatingGlass(in: .capsule)"), "膠囊用共用的系統玻璃(principal 沒有系統工具列膠囊)")
        #expect(title.contains(".navigationTitle("), "仍設系統標題(返回鈕、視窗標題用)")
        for pattern in ["Capsule()", ".glassEffect(", "Button {", "Button("] {
            #expect(!title.contains(pattern), "標題膠囊不自畫、不能點(\(pattern))")
        }
        for name in GlassLevelUsageTests.featureFiles {
            let text = try GlassLevelUsageTests.source(name)
            #expect(!text.contains("ConversationTitleView"), "\(name) 不該再有舊的自畫標題膠囊")
            #expect(!text.contains("titleCapsuleHeight"), "\(name) 不該有標題膠囊尺寸")
            #expect(!text.contains("\"exclamationmark.shield\""), "\(name) 不該有橘色權限盾牌")
        }
    }

    @Test("沒有 Inspector 開關鈕,也沒有 sidebar.trailing")
    func noInspectorToggle() throws {
        for name in GlassLevelUsageTests.featureFiles {
            let text = try GlassLevelUsageTests.source(name)
            #expect(!text.contains("conversation.inspectorToggle"), "\(name) 不該有 Inspector 開關鈕")
            #expect(!text.contains("sidebar.trailing"), "\(name) 不該有側欄圖示")
            #expect(!text.contains(".inspector(isPresented"), "\(name) 不該有右側 Inspector 欄")
        }
    }

    @Test("用量環永遠顯示:不再依用量資料決定要不要放環")
    func usageRingAlwaysShown() throws {
        let text = try GlassLevelUsageTests.source("AgentListView.swift")
        #expect(!text.contains("if let usageSummary {"), "用量環不該因為沒有資料就不放")
        #expect(text.contains("UsageRingButton("))
    }

    @Test("面板:iPad／寬視窗 popover、iPhone sheet,左上 X")
    func panelPresentation() throws {
        let text = try GlassLevelUsageTests.source("ConversationPanel.swift")
        #expect(text.contains("popover(isPresented"))
        #expect(text.contains("sheet(isPresented"))
        #expect(text.contains("appSheet(detents: [.medium, .large])"))
        #expect(text.contains("SheetCloseToolbar("))
    }
}
