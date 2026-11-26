import Foundation
import Testing

/// 玻璃層級(DESIGN.md「Liquid Glass」):sheet 回到系統 Liquid Glass(#614,推翻 #533;半高透出玻璃、全高不透明由系統決定),
/// 不自訂 sheet 底色,detent 經 `appSheet(detents:)`;浮在內容上的跳到最新鈕用系統 `.glass` 按鈕樣式(#627),離線橫幅走 `floatingGlass`。
@Suite("玻璃層級用法")
struct GlassLevelUsageTests {
    static let featuresFolder = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "src/PurrdrFeatures")

    static func source(_ name: String) throws -> String {
        try String(contentsOf: featuresFolder.appending(path: name), encoding: .utf8)
    }

    static var featureFiles: [String] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: featuresFolder, includingPropertiesForKeys: nil)) ?? []
        return urls.map(\.lastPathComponent).filter { $0.hasSuffix(".swift") }.sorted()
    }

    @Test("sheet 用系統 Liquid Glass(#614,推翻 #533):不自訂 sheet 底色,不用 presentationBackground／appSheetBackground")
    func sheetsKeepSystemGlass() throws {
        for name in Self.featureFiles {
            let text = try Self.source(name)
            #expect(!text.contains("presentationBackground("), "\(name) 不要蓋掉 sheet 的系統玻璃")
            #expect(!text.contains("appSheetBackground"), "\(name) 不要用自訂的不透明 sheet 底色")
            if name != "AppSurface.swift" {
                #expect(!text.contains(".presentationDetents("), "\(name) 的 detent 改用 appSheet(detents:)")
            }
        }
    }

    @Test("sheet 內的清單只隱藏預設底,不鋪不透明頁面底或列底")
    func sheetListsKeepSystemSurface() throws {
        // 新增聊天(#621)已是 push 的頁面,不是 sheet,不在這裡。
        // 只在 sheet 裡出現的畫面(聊天選單 sheet、歡迎頁、帳號與 Plus、新 worktree、主機信任)一律如此。
        for name in ["ModelCapsule.swift", "ConversationMenuSheets.swift", "WelcomeView.swift", "HostTrustView.swift", "PlusView.swift",
                     "PlusFeatures.swift", "AccountEntryViews.swift", "WorkspaceActionsViews.swift"] {
            let text = try Self.source(name)
            #expect(!text.contains(".appGroupedList()"), "\(name) 的 sheet 清單改用 appSheetList()")
            #expect(text.contains(".appSheetList()"), "\(name) 找不到 appSheetList()")
        }
        let surface = try Self.source("AppSurface.swift")
        let start = try #require(surface.range(of: "func appSheetList()"))
        let window = String(surface[start.lowerBound...].prefix(200))
        #expect(!window.contains("listRowBackground"), "appSheetList 不再設不透明列底")
    }

    @Test("浮動玻璃只用系統 glassEffect,輔助功能設定交給系統(#614):沒有 forcesOpaqueGlass 旗標與自畫的不透明版本")
    func floatingGlassIsSystemOnly() throws {
        for name in Self.featureFiles {
            #expect(!(try Self.source(name)).contains("forcesOpaque"), "\(name) 不要再有不透明玻璃旗標")
        }
        let glass = try Self.source("FloatingGlass.swift")
        #expect(glass.contains(".glassEffect(.regular"))
        #expect(!glass.contains("accessibilityReduceTransparency"))
    }

    @Test("聊天面板(#617)不鋪自己的底色:iPhone sheet 透出系統玻璃,popover 用系統底")
    func conversationPanelKeepsSystemSurface() throws {
        let text = try Self.source("ConversationPanel.swift")
        #expect(!text.contains("AppSurface."), "面板不鋪自訂底色")
        #expect(!text.contains(".background("), "面板不鋪自訂底色")
    }

    @Test("新增聊天是 push 的頁面(#621),不是部分高度的 sheet")
    func newChatIsPushedPage() throws {
        #expect(try Self.source("TopNavigationView.swift").contains("NewChatPage"))
        #expect(!(try Self.source("NewChatView.swift")).contains("appSheet(detents:"))
    }

    @Test("跳到最新鈕用系統 .glass 按鈕樣式(#627),不自畫玻璃、不自加尺寸")
    func jumpToLatestUsesSystemGlassButton() throws {
        let text = try Self.source("ConversationView.swift")
        let start = try #require(text.range(of: "Jump to Latest"))
        let window = String(text[start.lowerBound...].prefix(600))
        #expect(window.contains(".buttonStyle(.glass)"))
        #expect(!window.contains("floatingGlass"))
        #expect(!window.contains(".frame(width: 44"))
    }

    @Test("資料用量頁(#627):內容層不用玻璃,膠囊是系統 bordered")
    func dataUsageHasNoContentGlass() throws {
        let text = try Self.source("DataUsageView.swift")
        #expect(!text.contains("glassEffect"))
        #expect(!text.contains("floatingGlass"))
        #expect(text.contains(".buttonStyle(.bordered)"))
        #expect(text.contains(".buttonBorderShape(.capsule)"))
    }

    @Test("停止鈕是系統 bordered 膠囊(#627),沒有自訂 ButtonStyle")
    func stopButtonIsSystemBordered() throws {
        let text = try Self.source("StopBar.swift")
        #expect(!text.contains(": ButtonStyle"))
        #expect(!text.contains("StopBarButtonStyle"))
        #expect(text.contains("buttonStyle(.bordered)"))
        #expect(text.contains(".buttonBorderShape(.capsule)"))
    }
}
