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
}
