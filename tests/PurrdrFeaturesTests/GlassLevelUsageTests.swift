import Foundation
import Testing

/// 玻璃層級(DESIGN.md「Liquid Glass」):sheet 回到系統 Liquid Glass(#614,推翻 #533;半高透出玻璃、全高不透明由系統決定),
/// 不自訂 sheet 底色,detent 經 `appSheet(detents:)`;浮在內容上的跳到最新鈕與離線橫幅走 `floatingGlass`,減少透明度時不透明。
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
        for name in ["ModelCapsule.swift"] {
            let text = try Self.source(name)
            #expect(!text.contains(".appGroupedList()"), "\(name) 的 sheet 清單改用 appSheetList()")
            #expect(text.contains(".appSheetList()"), "\(name) 找不到 appSheetList()")
        }
        let surface = try Self.source("AppSurface.swift")
        let start = try #require(surface.range(of: "func appSheetList()"))
        let window = String(surface[start.lowerBound...].prefix(200))
        #expect(!window.contains("listRowBackground"), "appSheetList 不再設不透明列底")
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

    @Test("跳到最新鈕走 floatingGlass(減少透明度時不透明),不直接用 .glass 按鈕樣式")
    func jumpToLatestUsesFloatingGlass() throws {
        let text = try Self.source("ConversationView.swift")
        let start = try #require(text.range(of: "Jump to Latest"))
        let window = String(text[start.lowerBound...].prefix(500))
        #expect(window.contains("floatingGlass"))
        #expect(!window.contains(".buttonStyle(.glass)"))
    }
}
