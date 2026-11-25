import Foundation
import Testing

/// 小控制項改系統原生的原始碼守門(#627、spec #612):不自畫的就不要長回來。
@Suite("小控制項用系統原生")
struct SmallControlsUsageTests {
    static let featuresFolder = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "src/PurrdrFeatures")

    static func source(_ name: String) throws -> String {
        try String(contentsOf: featuresFolder.appending(path: name), encoding: .utf8)
    }

    @Test("做完再送是系統 Toggle,停用時 .disabled,不再用按鈕假裝開關或跳 alert")
    func sendWhenDoneIsSystemToggle() throws {
        let text = try Self.source("SendWhenDoneViews.swift")
        let start = try #require(text.range(of: "struct SendWhenDoneToggle"))
        let end = try #require(text.range(of: "struct SendWhenDoneQueueView"))
        let window = String(text[start.lowerBound..<end.lowerBound])
        #expect(window.contains("Toggle(isOn:"))
        #expect(window.contains(".disabled("))
        #expect(!window.contains(".alert("))
        #expect(!window.contains(".isToggle"))
        #expect(!window.contains(".opacity("))
    }

    @Test("流量頁整頁是系統 List,列尾 > 與分隔線由系統給")
    func dataUsageIsList() throws {
        let text = try Self.source("DataUsageView.swift")
        #expect(text.contains("List {"))
        #expect(!text.contains("ScrollView"))
        #expect(!text.contains("Divider()"))
        #expect(!text.contains("chevron.right"))
        #expect(!text.contains(".buttonStyle(.plain)"))
    }

    @Test("模型 sheet 的 Effort 列是 NavigationLink,不自放 chevron")
    func effortRowIsNavigationLink() throws {
        let text = try Self.source("ModelCapsule.swift")
        #expect(text.contains("NavigationLink(value: ModelEffortRoute())"))
        #expect(!text.contains("chevron.forward"))
    }

    @Test("Git 變更底部列與看圖用系統的 safeAreaBar／工具列,不自鋪 .bar 或自排浮動按鈕")
    func barsAreSystem() throws {
        let changes = try Self.source("ChangesView.swift")
        #expect(changes.contains(".safeAreaBar(edge: .bottom)"))
        #expect(!changes.contains(".background(.bar)"))
        let viewer = try Self.source("ImageViewer.swift")
        #expect(viewer.contains("SheetCloseToolbar"))
        #expect(viewer.contains("ToolbarItem(placement: .primaryAction)"))
        #expect(!viewer.contains(".buttonStyle(.glass)"))
        #expect(!viewer.contains("minWidth: 44"))
    }

    @Test("子 Agent 頁頂部是系統副標題,不自鋪 .bar")
    func subagentUsesNavigationSubtitle() throws {
        let text = try Self.source("DelegationViews.swift")
        let start = try #require(text.range(of: "struct SubagentScreen:"))
        let window = String(text[start.lowerBound...].prefix(1_500))
        #expect(window.contains(".navigationSubtitle("))
        #expect(!window.contains(".background(.bar)"))
        #expect(!window.contains("safeAreaInset"))
    }

    @Test("用量面板是系統 Section:不自畫圓角卡片底")
    func usagePanelUsesSections() throws {
        let text = try Self.source("ConversationUsageViews.swift")
        #expect(!text.contains("AppSurface.groupedRow"))
        #expect(text.contains("Section(\"This Chat\")"))
    }

    @Test("機密偵測清單是系統清單,按鈕在 safeAreaBar")
    func secretCheckUsesList() throws {
        let text = try Self.source("SecretCheckViews.swift")
        #expect(text.contains("List {"))
        #expect(text.contains(".safeAreaBar(edge: .bottom)"))
        #expect(!text.contains("Divider()"))
    }
}
