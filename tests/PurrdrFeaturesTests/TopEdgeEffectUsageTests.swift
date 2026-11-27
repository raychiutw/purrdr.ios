import Foundation
import Testing

/// 頂端不要遮罩(#682、spec #681,DESIGN.md「可讀性」):頂端的 scroll edge effect 只在共用頁面設定 `PageTopEdge.swift` 決定。
/// 各頁不直接寫 `scrollEdgeEffectHidden` 或 `topEdgeEffect`,一律套 `appPageTopEdge()` / `hidesTopEdgeEffect()`。
@Suite("頂端不要遮罩用法")
struct TopEdgeEffectUsageTests {
    static let sharedFile = "PageTopEdge.swift"

    @Test("scrollEdgeEffectHidden 與 topEdgeEffect 只出現在共用頁面設定")
    func onlyTheSharedSettingTouchesTopEdgeEffect() throws {
        for name in GlassLevelUsageTests.featureFiles where name != Self.sharedFile {
            let text = try GlassLevelUsageTests.source(name)
            #expect(!text.contains("scrollEdgeEffectHidden"), "\(name) 不要直接關 scroll edge effect,改用 appPageTopEdge()")
            #expect(!text.contains("topEdgeEffect"), "\(name) 不要直接設 topEdgeEffect,改用 hidesTopEdgeEffect()")
        }
        let shared = try GlassLevelUsageTests.source(Self.sharedFile)
        #expect(shared.contains("scrollEdgeEffectHidden(true, for: .top)"))
        #expect(shared.contains("topEdgeEffect.isHidden"))
        #expect(!shared.contains("bottomEdgeEffect") && !shared.contains("for: .bottom"), "底部的效果不動")
    }

    @Test("聊天畫面與聊天列表套用共用設定")
    func conversationAppliesIt() throws {
        #expect(try GlassLevelUsageTests.source("ConversationView.swift").contains(".appPageTopEdge()"))
        #expect(try GlassLevelUsageTests.source("ChatListView.swift").contains("hidesTopEdgeEffect()"))
    }

    @Test("減少透明度時狀態列改不透明的系統底色")
    func reducedTransparencyIsOpaque() throws {
        let shared = try GlassLevelUsageTests.source(Self.sharedFile)
        #expect(shared.contains("accessibilityReduceTransparency"))
        #expect(shared.contains("systemBackground"))
    }

    // MARK: 全 app(#683)

    /// 有垂直捲動容器、但刻意不套共用設定的檔案與原因。
    static let exemptions: [String: String] = [
        "PaneTerminalView.swift": "Pane 終端機是 SwiftTerm 的畫面,不是捲動內容疊在導覽列下;維持原樣,只有橫向捲動的小元件",
        "ShellRunView.swift": "登入 Shell 同為終端機畫面,維持原樣;只有橫向捲動的按鍵列",
        "NeedsYouCard.swift": "輸入列上方的浮動卡片內的小捲動區,不是頁面",
        "SlashMenuView.swift": "輸入列上方的 slash 浮動面板,不是頁面",
        "MarkdownView.swift": "訊息內的橫向捲動(程式碼、表格),不是頁面",
        "BlockedPromptView.swift": "訊息內的橫向捲動,不是頁面",
    ]

    static let applyMarkers = [".appPageTopEdge()", ".appScrollTopEdge()", ".appGroupedList()", ".appSheetList()", "hidesTopEdgeEffect()"]

    /// 去掉註解與橫向的 ScrollView 後,是否還有垂直捲動容器(List／Form／ScrollView／UICollectionView 建立)。
    static func hasVerticalScroller(_ text: String) -> Bool {
        let code = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("///") }
        return code.contains { line in
            let l = String(line)
            if l.contains("ScrollView(.horizontal") { return false }
            return l.range(of: #"\b(List|Form|ScrollView)\b *(\(|\{)"#, options: .regularExpression) != nil
                || l.contains("UICollectionView(frame")
        }
    }

    @Test("有垂直捲動容器的頁面都套用共用的頂端設定,例外附原因")
    func everyScrollingPageApplies() throws {
        for name in GlassLevelUsageTests.featureFiles where name != Self.sharedFile {
            let text = try GlassLevelUsageTests.source(name)
            guard Self.hasVerticalScroller(text) else { continue }
            if Self.exemptions[name] != nil { continue }
            #expect(Self.applyMarkers.contains { text.contains($0) }, "\(name) 有捲動容器卻沒套用頂端設定(appPageTopEdge／appScrollTopEdge／appGroupedList／appSheetList)")
        }
    }

    @Test("例外清單只列真的存在且確實不套用的檔案")
    func exemptionsAreHonest() throws {
        for (name, reason) in Self.exemptions {
            let text = try GlassLevelUsageTests.source(name)
            #expect(!reason.isEmpty)
            #expect(!Self.applyMarkers.contains { text.contains($0) }, "\(name) 已套用,不必列例外")
        }
    }

    @Test("appGroupedList 與 appSheetList 帶頂端設定,不能被繞過")
    func listModifiersCarryTheSetting() throws {
        let surface = try GlassLevelUsageTests.source("AppSurface.swift")
        let grouped = try #require(surface.range(of: "func appGroupedList()"))
        #expect(String(surface[grouped.lowerBound...].prefix(260)).contains("appPageTopEdge()"))
        let sheet = try #require(surface.range(of: "func appSheetList()"))
        #expect(String(surface[sheet.lowerBound...].prefix(200)).contains("appScrollTopEdge()"))
    }

    @Test("共用頁面設定提供 sheet 用的只關捲動效果版本")
    func sharedSettingHasScrollOnlyVariant() throws {
        let shared = try GlassLevelUsageTests.source(Self.sharedFile)
        #expect(shared.contains("func appScrollTopEdge()"))
    }
}
