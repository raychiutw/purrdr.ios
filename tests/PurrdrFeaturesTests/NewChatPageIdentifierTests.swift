import Foundation
import Testing

/// 新增聊天的 `newChat.page` identifier 必須在 `appGroupedList()` 之前(#683 之後 `appGroupedList` 會疊頂端淡模糊,
/// 疊在 identifier 之後就繼承它,UI 測試 `swipeUp` 抓到 54pt 高的那條、表單捲不動,`newChat.folder` 找不到)。
@Suite("新增聊天頁面 identifier")
struct NewChatPageIdentifierTests {
    @Test("newChat.page 在 appGroupedList 之前")
    func identifierComesBeforeGroupedList() throws {
        let text = try GlassLevelUsageTests.source("NewChatView.swift")
        let identifier = try #require(text.range(of: #".accessibilityIdentifier("newChat.page")"#))
        let list = try #require(text.range(of: ".appGroupedList()"))
        #expect(identifier.lowerBound < list.lowerBound, "identifier 要在 appGroupedList() 之前,否則頂端淡模糊會繼承它")
    }
}
