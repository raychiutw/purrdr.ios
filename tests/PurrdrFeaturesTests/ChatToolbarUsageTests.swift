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

    @Test("聊天標題是系統標題加副標題,不自畫標題膠囊、狀態點與權限盾牌(#618)")
    func systemTitleAndSubtitle() throws {
        let view = try GlassLevelUsageTests.source("ConversationView.swift")
        #expect(!view.contains("placement: .principal"), "聊天頂列不放自畫的 principal 標題")
        let title = try GlassLevelUsageTests.source("ConversationListContentBuilder.swift")
        #expect(title.contains(".navigationSubtitle("), "狀態文字用系統副標題")
        for name in GlassLevelUsageTests.featureFiles {
            let text = try GlassLevelUsageTests.source(name)
            #expect(!text.contains("ConversationTitleView"), "\(name) 不該再有標題膠囊")
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
