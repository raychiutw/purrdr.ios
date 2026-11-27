#if os(iOS)
import Foundation
import Testing
import UIKit
@testable import PurrdrAgentFeatures
@testable import PurrdrCore
@testable import PurrdrFeatures
import PurrdrTestSupport

/// 頂端不要遮罩(#682、spec #681):聊天列表的 collection view 關掉頂端 scroll edge effect,底部不動。
@Suite(.serialized)
@MainActor
struct ChatListTopEdgeEffectTests {
    static let layoutTests = ConversationLayoutTests()

    @Test("聊天列表的頂端 scroll edge effect 已關掉,底部維持系統預設")
    func topEdgeEffectIsHidden() async throws {
        let mounted = try await Self.layoutTests.open(window: Array(ConversationLayoutTests.lines[0...12]))
        defer { mounted.chat.cancel(); mounted.window.isHidden = true }
        try await Self.layoutTests.waitForFollow(mounted)
        try await Task.sleep(for: .milliseconds(600))
        let collection = try #require(ConversationLayoutTests.findCollectionView(mounted.window))
        #expect(collection.topEdgeEffect.isHidden)
        #expect(!collection.bottomEdgeEffect.isHidden)
    }
}
#endif
