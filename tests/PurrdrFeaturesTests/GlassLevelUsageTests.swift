import Foundation
import Testing

/// 玻璃層級(DESIGN.md「Liquid Glass」):所有 sheet 底色統一為不透明(#533,取代 #425 的「部分高度 sheet 透出玻璃」),
/// 一律經 `appSheet(detents:)`／`appSheetBackground()`;浮在內容上的跳到最新鈕與離線橫幅走 `floatingGlass`,減少透明度時不透明。
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

    @Test("所有 sheet 底色統一為不透明(#533):不直接呼叫 presentationBackground/presentationDetents,一律經 appSheet")
    func sheetsShareOneOpaqueBackground() throws {
        for name in Self.featureFiles where name != "AppSurface.swift" {
            let text = try Self.source(name)
            #expect(!text.contains(".presentationBackground("), "\(name) 的 sheet 底色改用 appSheet()／appSheetBackground()")
            #expect(!text.contains(".presentationDetents("), "\(name) 的 detent 改用 appSheet(detents:)")
        }
    }

    @Test("每個 .sheet( 的內容都套 appSheet 或 appSheetBackground")
    func everySheetAppliesTheSheetBackground() throws {
        let sheetCall = try Regex(#"\.sheet\("#)
        let applied = try Regex(#"\.appSheet(Background)?\("#)
        for name in Self.featureFiles {
            let text = try Self.source(name)
            let sheets = text.matches(of: sheetCall).count
            guard sheets > 0 else { continue }
            #expect(text.matches(of: applied).count >= sheets, "\(name) 有 \(sheets) 個 .sheet( 但套用底色的次數不足")
        }
    }

    @Test("sheet 內的清單不鋪頁面底、也不用 appGroupedList(底色由 sheet 本身提供)")
    func sheetListsKeepOnlyRowBackground() throws {
        for name in ["ModelCapsule.swift", "NewChatView.swift"] {
            let text = try Self.source(name)
            #expect(!text.contains(".appGroupedList()"), "\(name) 的 sheet 清單改用 appSheetList()")
            #expect(text.contains(".appSheetList()"), "\(name) 找不到 appSheetList()")
        }
    }

    @Test("iPad 對話右側 Inspector 用不透明的 AppSurface.sheet 底色(#547),不留半透明欄底")
    func inspectorUsesOpaqueSheetSurface() throws {
        let text = try Self.source("ConversationInspector.swift")
        #expect(text.contains(".background(AppSurface.sheet)"), "Inspector 內容底色用 AppSurface.sheet")
        #expect(text.contains(".background(AppSurface.sheet.ignoresSafeArea())"), "右側欄本身也鋪 AppSurface.sheet")
        #expect(!text.contains("AppSurface.groupedPage"), "Inspector 底色統一走 AppSurface.sheet")
    }

    @Test("新增聊天 sheet 是部分高度")
    func newChatIsPartialHeight() throws {
        #expect(try Self.source("TopNavigationView.swift").contains("NewChatSheet"))
        #expect(try Self.source("NewChatView.swift").contains("appSheet(detents: [.medium, .large])"))
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
