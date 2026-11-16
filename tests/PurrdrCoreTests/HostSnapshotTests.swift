import Foundation
import PurrdrCore
import Testing

@Suite("Host snapshot")
struct HostSnapshotTests {
    @Test("終端機 pane:不屬於任何 Agent 的 pane")
    func terminalPanes() {
        let snapshot = HostSnapshot(
            version: "0.9.5",
            agents: [Agent(paneID: "w1:p1", workspaceID: "w1", kind: "claude", status: .idle)],
            panes: [
                Pane(id: "w1:p1", workspaceID: "w1", tabID: "w1:t1"),
                Pane(id: "w1:p2", workspaceID: "w1", tabID: "w1:t1", label: "zsh"),
            ])

        #expect(snapshot.terminalPanes.map(\.id) == ["w1:p2"])
    }
}
