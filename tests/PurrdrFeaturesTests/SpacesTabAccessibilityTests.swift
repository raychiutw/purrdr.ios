import Foundation
import PurrdrAgentFeatures
import PurrdrCore
@testable import PurrdrFeatures
import Testing

/// Spaces 列的 VoiceOver 句子(#316):頭像與狀態圓點不另成元素，由列念出 Tab 名稱、Agent 種類與狀態。
@MainActor
@Suite("Spaces 列的 VoiceOver")
struct SpacesTabAccessibilityTests {
    @Test("有 Agent:Tab 名稱、種類、狀態")
    func agentTab() {
        let tab = SpacesTab(
            host: .demo, key: "w1:t1", title: "CSV 匯出", target: .pane(ChatRoute(host: .demo, paneID: "w1:p1")),
            avatar: .agent(kind: "claude", status: .blocked))

        #expect(SpacesTabLabel.accessibilityText(tab) == "CSV 匯出, Claude Code, Needs You")
    }

    @Test("只有終端機：Tab 名稱與「終端機」,沒有狀態")
    func terminalTab() {
        let tab = SpacesTab(
            host: .demo, key: "w2:t1", title: "Shell", target: .pane(ChatRoute(host: .demo, paneID: "w2:p1")), avatar: .terminal)

        #expect(SpacesTabLabel.accessibilityText(tab) == "Shell, Terminal")
    }
}
