import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// Pane 在電腦上的實際格數(#357):保留電腦版面時 handshake 要帶它，Pane 才不會被改成手機的大小。
/// 案例的數字是 herdr 0.9.5 真主機實測(docs/research/terminal-session-control-macos.md 末段)。
@Suite("Pane 在電腦上的格數")
struct PaneNativeSizeTests {
    private func snapshot(
        panes: [(id: String, rect: GridRect, rows: Int?)], zoomed: Bool = false
    ) -> HostSnapshot {
        HostSnapshot(
            version: "0.9.5", agents: [],
            panes: panes.map { Pane(id: $0.id, workspaceID: "w1", tabID: "w1:tA", viewportRows: $0.rows) },
            layouts: [TabLayout(
                workspaceID: "w1", tabID: "w1:tA", zoomed: zoomed, focusedPaneID: panes.first?.id,
                panes: panes.map { TabLayout.PaneRect(paneID: $0.id, rect: $0.rect) })])
    }

    @Test("單一 Pane:電腦視窗 160×50 → layout 134×49、viewport_rows 49 → PTY 133×49(扣 1 欄 scrollbar)")
    func singlePane() {
        let snapshot = snapshot(panes: [("w1:p1", GridRect(x: 0, y: 0, width: 134, height: 49), 49)])

        #expect(snapshot.nativeSize(ofPane: "w1:p1") == PaneNativeSize(columns: 133, rows: 49))
    }

    @Test("左右分割的 Pane:rect 67×49、viewport_rows 47 → PTY 64×47(再扣左右邊框各 1 欄)")
    func splitPane() {
        let snapshot = snapshot(panes: [
            ("w1:p1", GridRect(x: 0, y: 0, width: 67, height: 49), 47),
            ("w1:p2", GridRect(x: 67, y: 0, width: 67, height: 49), 47),
        ])

        #expect(snapshot.nativeSize(ofPane: "w1:p1") == PaneNativeSize(columns: 64, rows: 47))
    }

    @Test("alternate screen 沒有 scrollbar:分割的 Pane 欄數是 65")
    func alternateScreenKeepsGutterColumn() {
        let snapshot = snapshot(panes: [
            ("w1:p1", GridRect(x: 0, y: 0, width: 67, height: 49), 47),
            ("w1:p2", GridRect(x: 67, y: 0, width: 67, height: 49), 47),
        ])

        #expect(snapshot.nativeSize(ofPane: "w1:p1", isAlternateScreen: true) == PaneNativeSize(columns: 65, rows: 47))
    }

    @Test("放大(zoomed)只有一個 Pane 顯示:不扣分割邊框")
    func zoomedPaneHasNoSplitBorders() {
        let snapshot = snapshot(panes: [
            ("w1:p1", GridRect(x: 0, y: 0, width: 134, height: 49), 49),
            ("w1:p2", GridRect(x: 0, y: 0, width: 134, height: 49), 49),
        ], zoomed: true)

        #expect(snapshot.nativeSize(ofPane: "w1:p1") == PaneNativeSize(columns: 133, rows: 49))
    }

    @Test("電腦上沒開 herdr(headless):layout 恆為 120×40 預設，與 PTY 無關,回 nil")
    func headlessLayoutIsUnknown() {
        let snapshot = snapshot(panes: [("w1:p1", GridRect(x: 0, y: 0, width: 120, height: 40), 30)])

        #expect(snapshot.nativeSize(ofPane: "w1:p1") == nil)
    }

    @Test("headless 且分割:各 Pane 加起來是 120×40 也算沒有電腦版面")
    func headlessSplitLayoutIsUnknown() {
        let snapshot = snapshot(panes: [
            ("w1:p1", GridRect(x: 0, y: 0, width: 60, height: 40), 40),
            ("w1:p2", GridRect(x: 60, y: 0, width: 60, height: 40), 40),
        ])

        #expect(snapshot.nativeSize(ofPane: "w1:p2") == nil)
    }

    @Test("欄位不全就不猜:沒有 viewport_rows、不在 layout 裡、主機沒回報 layout")
    func missingDataIsUnknown() {
        let rect = GridRect(x: 0, y: 0, width: 134, height: 49)
        #expect(snapshot(panes: [("w1:p1", rect, nil)]).nativeSize(ofPane: "w1:p1") == nil)
        #expect(snapshot(panes: [("w1:p1", rect, 49)]).nativeSize(ofPane: "w1:p9") == nil)
        let withoutLayouts = HostSnapshot(
            version: "0.9.5", agents: [], panes: [Pane(id: "w1:p1", workspaceID: "w1", tabID: "w1:tA", viewportRows: 49)], layouts: nil)
        #expect(withoutLayouts.nativeSize(ofPane: "w1:p1") == nil)
    }

    @Test("寬度 ≤ 4 的 Pane 沒有 scrollbar:不扣欄")
    func tinyPaneKeepsWidth() {
        let snapshot = snapshot(panes: [("w1:p1", GridRect(x: 0, y: 0, width: 4, height: 10), 10)])

        #expect(snapshot.nativeSize(ofPane: "w1:p1") == PaneNativeSize(columns: 4, rows: 10))
    }

    @Test("snapshot 的 scroll.viewport_rows 讀進 Pane(真主機錄製檔)")
    func viewportRowsComeFromSnapshot() async throws {
        let host = FakeHost()
        await host.expect(HerdrCommand.bridge(), reply: .recorded("session.snapshot.ndjson"))

        let snapshot = try await HerdrClient(channel: host).snapshot()

        #expect(snapshot.panes.contains { $0.viewportRows == 32 })
    }
}
