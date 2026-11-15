import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// Claude 的背景 agents 窗格(行為規格 §4.8「Claude 背景 agents 窗格」、F10「背景 agents 列」)。
///
/// `pane.read.agents-pane.ndjson`:作者 Mac 上一個有背景 agent 在跑的 Claude Code pane 的 `pane.read`(visible、40 行),
/// 2026-11-16 錄製。窗格的記號、種類、經過時間、tokens 與欄寬原樣;回覆內容、輸入框、狀態列與任務文字換成假值。
@Suite("背景 agents 窗格")
struct AgentsPaneTests {
    static var screen: String {
        let line = Fixtures.data("pane.read.agents-pane.ndjson")
        let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        let read = (object?["result"] as? [String: Any])?["read"] as? [String: Any]
        return read?["text"] as? String ?? ""
    }

    @Test("讀 pane 畫面：送 pane.read(visible、40 行),回傳畫面文字")
    func readPaneSendsVisibleRead() async throws {
        let host = FakeHost()
        await host.expect(HerdrCommand.bridge(), reply: .recorded("pane.read.agents-pane.ndjson"))

        let text = try await HerdrClient(channel: host).readPane(paneID: "w1:pA")

        #expect(text == Self.screen)
        let execution = await host.executions.first
        #expect(execution?.stdinText == #"{"id":"purrdr:pane.read","method":"pane.read","params":{"lines":40,"pane_id":"w1:pA","source":"visible"}}"# + "\n")
        #expect(execution?.closedStdin == false)
    }

    @Test("窗格：最後一個 ⏺ main 標頭之後的列;記號、種類、任務、經過時間、tokens;↓ N more 是折疊下的列數")
    func parsesRecordedPane() throws {
        let pane = try #require(AgentsPane.parse(screen: Self.screen))

        #expect(pane.rows.count == 5)
        #expect(pane.hiddenCount == 4)
        #expect(pane.rows.allSatisfy { $0.state == .running && $0.kind == "general-purpose" })
        #expect(pane.rows.map(\.task) == [
            "Rerunning the import UI tests", "Running the full test suite", "Updating the export button test",
            "Running ImportScreenUITests", "Removing a duplicate identifier in SettingsFooter.swift",
        ])
        // 19m 39s、1h 31m 0s、1h 26m 35s、1h 9m 1s、1h 16m 23s
        #expect(pane.rows.map(\.elapsedSeconds) == [1179, 5460, 5195, 4141, 4583])
        #expect(pane.rows.map(\.tokens) == [236_500, 362_700, 308_100, 145_500, 290_000])
    }

    @Test("記號：◯○ 執行中、⏺●◉✓✔ 完成、✗✘× 失敗;tokens 可以是 980、1,234、156.7k、1.2M")
    func markersAndTokenFormats() throws {
        // 以錄製畫面的窗格為底，改記號與 tokens(錄製時全部都在執行中)。
        let rows = [
            ("◯", "980", DelegationStatus.running, 980), ("○", "1,234", .running, 1234), ("⏺", "156.7k", .completed, 156_700),
            ("●", "1.2M", .completed, 1_200_000), ("◉", "1k", .completed, 1000), ("✓", "1", .completed, 1), ("✔", "2", .completed, 2),
            ("✗", "3", .failed, 3), ("✘", "4", .failed, 4), ("×", "5", .failed, 5),
        ]
        let screen = "  ⏺ main\n" + rows.map { "  \($0.0) Explore  Look around  12s · ↓ \($0.1) tokens" }.joined(separator: "\n")
        let pane = try #require(AgentsPane.parse(screen: screen))

        #expect(pane.rows.map(\.state) == rows.map(\.2))
        #expect(pane.rows.map(\.tokens) == rows.map(\.3))
        #expect(pane.hiddenCount == 0)
    }

    @Test("有多個 main 標頭時取最後一個;沒有標頭就沒有窗格")
    func lastHeaderWins() {
        let screen = "  ⏺ main\n  ◯ Explore  old task  1s · ↓ 1 tokens\nreply text\n  ● main\n  ✔ Fork  new task  2s · ↓ 2 tokens"
        #expect(AgentsPane.parse(screen: screen)?.rows.map(\.task) == ["new task"])
        #expect(AgentsPane.parse(screen: "no pane here\n❯ ") == nil)
    }
}
