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

    @Test("共用的訂閱:兩個視窗同時掛上,其中一個結束,另一個仍讓橫幅更新")
    func sharedRunSurvivesOneWindowClosing() async throws {
        let merged = await AgentListHostFilterTests.loadedModel { SnapshotEdit.agent("w1:pB", in: &$0) { $0["agent_status"] = "blocked" } }
        let notifications = NeedsYouNotifications()
        let mainWindow = Task { await notifications.runShared(observing: merged) }
        let paneWindow = Task { await notifications.runShared(observing: merged) }
        defer { paneWindow.cancel() }

        for _ in 0..<50 where notifications.others.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(notifications.others.map(\.route.paneID) == ["w1:pB"])

        mainWindow.cancel()
        _ = await mainWindow.value
        #expect(notifications.activeRunnerCount == 1)
        // 主視窗關掉後,只剩 Pane 視窗:列表變了橫幅輸出仍跟著更新(開著的聊天不算)。
        merged.chatAppeared(ChatRoute(host: Self.studio, paneID: "w1:pB"))
        for _ in 0..<50 where !notifications.others.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(notifications.others.isEmpty, "只剩 Pane 視窗時沒有繼續更新")
    }

    @Test("共用的訂閱:全部視窗結束後停止")
    func sharedRunStopsWhenAllWindowsEnd() async throws {
        let merged = await AgentListHostFilterTests.loadedModel()
        let notifications = NeedsYouNotifications()
        let a = Task { await notifications.runShared(observing: merged) }
        let b = Task { await notifications.runShared(observing: merged) }
        for _ in 0..<50 where notifications.activeRunnerCount < 2 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(notifications.activeRunnerCount == 2)
        a.cancel()
        b.cancel()
        _ = await a.value
        _ = await b.value
        #expect(notifications.activeRunnerCount == 0)
    }
}
