import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrTestSupport
@testable import PurrdrFeatures
import Testing

/// Pane 視窗的「需要你」橫幅(#546、#539):點橫幅的去向、與只剩 Pane 視窗時橫幅仍會更新。
@MainActor
@Suite("Pane 視窗需要你橫幅")
struct PaneWindowBannerTests {
    static let studio = AgentListHostFilterTests.studio

    @Test("有主視窗:點橫幅在主視窗開那個聊天")
    func opensInMainWindowWhenThereIsOne() {
        let target = ChatRoute(host: Self.studio, paneID: "w3:p1")
        let plan = PaneBannerOpenPlan.make(target: target, hasMainWindow: true, workspaceTitle: "notes")
        #expect(plan == .mainWindow(target))
    }

    @Test("沒有主視窗(只剩 Pane 視窗):點橫幅開新的 Pane 視窗,標題用 workspace 名稱")
    func opensNewPaneWindowWithoutMainWindow() {
        let target = ChatRoute(host: Self.studio, paneID: "w3:p1")
        let plan = PaneBannerOpenPlan.make(target: target, hasMainWindow: false, workspaceTitle: "notes")
        #expect(plan == .newPaneWindow(PaneWindow(kind: .chat, host: Self.studio, paneID: "w3:p1", sessionID: nil, title: "notes")))
    }

    @Test("沒有 workspace 名稱時標題退回 pane id")
    func titleFallsBackToPaneID() {
        let target = ChatRoute(host: Self.studio, paneID: "w3:p1")
        let plan = PaneBannerOpenPlan.make(target: target, hasMainWindow: false, workspaceTitle: nil)
        #expect(plan == .newPaneWindow(PaneWindow(kind: .chat, host: Self.studio, paneID: "w3:p1", sessionID: nil, title: "w3:p1")))
    }

    @Test("單一驅動:重複開始只有一個訂閱,停止後結束;停止時仍跟得上列表(開著的聊天不算)")
    func singleDriverStartsOnceAndStops() async throws {
        let merged = await AgentListHostFilterTests.loadedModel { SnapshotEdit.agent("w1:pB", in: &$0) { $0["agent_status"] = "blocked" } }
        let notifications = NeedsYouNotifications()
        notifications.drive(observing: merged, isActive: true)
        notifications.drive(observing: merged, isActive: true)
        #expect(notifications.isRunning)

        for _ in 0..<50 where notifications.others.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(notifications.others.map(\.route.paneID) == ["w1:pB"])
        merged.chatAppeared(ChatRoute(host: Self.studio, paneID: "w1:pB"))
        for _ in 0..<50 where !notifications.others.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(notifications.others.isEmpty)

        notifications.drive(observing: merged, isActive: false)
        #expect(!notifications.isRunning)
    }

    @Test("兩個視窗都要求驅動:apply 次數與一個視窗相同(量測)")
    func twoWindowsApplyOncePerInputChange() async throws {
        let merged = await AgentListHostFilterTests.loadedModel { SnapshotEdit.agent("w1:pB", in: &$0) { $0["agent_status"] = "blocked" } }
        let notifications = NeedsYouNotifications()
        notifications.drive(observing: merged, isActive: true)
        notifications.drive(observing: merged, isActive: true)
        for _ in 0..<50 where notifications.applyCount == 0 { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(notifications.applyCount == 1)
        merged.chatAppeared(ChatRoute(host: Self.studio, paneID: "w1:pB"))
        for _ in 0..<50 where notifications.applyCount < 2 { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(notifications.applyCount == 2)
        notifications.drive(observing: merged, isActive: false)
    }
}
