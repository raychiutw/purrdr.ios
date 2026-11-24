#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import PurrdrAgentFeatures
@testable import PurrdrCore
@testable import PurrdrFeatures
import PurrdrTestSupport

/// 返回列表的轉場期間(聊天畫面已經在離開)不再套用新內容:追加內容會讓整個聊天重算與重排,全塞進 pop 動畫裡。
/// 這裡用真正的 `ChatListViewController`:`viewWillDisappear` 之後進來的內容先留著,`viewWillAppear`(取消返回、從子頁回來)再接上。
@Suite(.serialized)
@MainActor
struct ChatListLeavingIOSTests {
    static let layoutTests = ConversationLayoutTests()

    @Test("離開中進來的新訊息先不顯示,回來之後才接上")
    func holdsNewContentWhileLeaving() async throws {
        var mounted = try await Self.layoutTests.open(window: Array(ConversationLayoutTests.lines[0...12]))
        defer { mounted.chat.cancel(); mounted.window.isHidden = true }
        try await Self.layoutTests.waitForFollow(mounted)
        try await Task.sleep(for: .milliseconds(600))
        let collection = try #require(ConversationLayoutTests.findCollectionView(mounted.window))
        let controller = try #require(HitchRecorderIOSTests.controller(of: collection))
        let before = collection.numberOfItems(inSection: 0)
        #expect(before > 0)

        controller.beginAppearanceTransition(false, animated: false)
        controller.endAppearanceTransition()
        await Self.layoutTests.push(ConversationLayoutTests.textLine(950, "離開中進來的訊息"), to: &mounted)
        try await Task.sleep(for: .milliseconds(500))
        #expect(collection.numberOfItems(inSection: 0) == before, "離開中不該套用新內容")

        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        for _ in 0..<100 where collection.numberOfItems(inSection: 0) == before {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(collection.numberOfItems(inSection: 0) > before, "回來之後要接上離開中收到的內容")
    }

    @Test("沒有離開時新訊息照常顯示")
    func appliesNewContentWhenNotLeaving() async throws {
        var mounted = try await Self.layoutTests.open(window: Array(ConversationLayoutTests.lines[0...12]))
        defer { mounted.chat.cancel(); mounted.window.isHidden = true }
        try await Self.layoutTests.waitForFollow(mounted)
        try await Task.sleep(for: .milliseconds(600))
        let collection = try #require(ConversationLayoutTests.findCollectionView(mounted.window))
        let before = collection.numberOfItems(inSection: 0)

        await Self.layoutTests.push(ConversationLayoutTests.textLine(951, "照常進來的訊息"), to: &mounted)
        for _ in 0..<100 where collection.numberOfItems(inSection: 0) == before {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(collection.numberOfItems(inSection: 0) > before)
    }
}
#endif
