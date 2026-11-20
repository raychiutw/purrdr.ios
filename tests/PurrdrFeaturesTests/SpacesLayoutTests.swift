import Foundation
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// Spaces 版面圖(行為規格 F4):以錄製的 snapshot 為底投影成 tab 與 pane 方塊。
@Suite("Spaces 版面圖")
struct SpacesLayoutTests {
    static func snapshot(modify: ((inout [String: Any]) -> Void)? = nil) async throws -> HostSnapshot {
        let host = FakeHost()
        let reply: FakeReply = modify.map { .recorded("session.snapshot.ndjson", modify: $0) } ?? .recorded("session.snapshot.ndjson")
        await host.expect(HerdrCommand.bridge(), reply: reply)
        return try await HerdrClient(channel: host).snapshot()
    }

    /// 改錄製 snapshot 的 `layouts[]`。
    static func editLayouts(_ response: inout [String: Any], _ change: (inout [[String: Any]]) -> Void) {
        var result = response["result"] as? [String: Any] ?? [:]
        var snapshot = result["snapshot"] as? [String: Any] ?? [:]
        var layouts = snapshot["layouts"] as? [[String: Any]] ?? []
        change(&layouts)
        snapshot["layouts"] = layouts
        result["snapshot"] = snapshot
        response["result"] = result
    }

    static func rect(_ x: Int, _ y: Int, _ width: Int, _ height: Int) -> [String: Any] {
        ["x": x, "y": y, "width": width, "height": height]
    }

    @Test("tab 依順序排列，作用中的 tab 有標示;單一 pane 的 tab 是一個佔滿的 agent 方塊，點了開它的聊天")
    func tabsInOrderWithAgentBlocks() async throws {
        let layout = try #require(SpacesLayout(snapshot: try await Self.snapshot(), workspaceID: "w1"))

        #expect(layout.tabs.map(\.id) == ["w1:t6", "w1:tA", "w1:tB"])
        #expect(layout.tabs.map(\.label) == ["1", "2", "3"])
        #expect(layout.tabs.map(\.isActive) == [false, true, false])
        let first = try #require(layout.tabs.first)
        #expect(first.paneCount == 1)
        #expect(first.blocks == [
            SpacesLayout.Block(
                id: "w1:p6", frame: .init(x: 0, y: 0, width: 1, height: 1),
                content: .agent(name: "Claude Code", detail: "整理植物照片的標籤", status: .idle),
                isFocused: true, target: .chat(paneID: "w1:p6")
            ),
        ])
    }

    @Test("從 Spaces 檢視點有多個 pane 的 Tab:版面圖只留那個 Tab;找不到時照原樣(#275)")
    func onlyTab() async throws {
        let layout = try #require(SpacesLayout(snapshot: try await Self.snapshot(), workspaceID: "w1"))

        #expect(layout.onlyTab("w1:tA").tabs.map(\.id) == ["w1:tA"])
        #expect(layout.onlyTab("w9:t1").tabs.map(\.id) == ["w1:t6", "w1:tA", "w1:tB"])
    }

    @Test("分頁形狀：長寬比 = (欄 × 0.5) / 列,限制在 0.9–2.4")
    func aspectRatioIsClamped() async throws {
        let snapshot = try await Self.snapshot { response in
            Self.editLayouts(&response) { layouts in
                // w1:tA 改成 60 欄 × 40 列 → 0.75,夾到 0.9;w1:tB 改成 100 欄 × 25 列 → 2.0。
                layouts[1]["panes"] = [["pane_id": "w1:pA", "focused": true, "rect": Self.rect(0, 0, 60, 40)]]
                layouts[2]["panes"] = [["pane_id": "w1:pB", "focused": true, "rect": Self.rect(0, 0, 100, 25)]]
            }
        }
        let layout = try #require(SpacesLayout(snapshot: snapshot, workspaceID: "w1"))

        // 錄製的 164 × 32 → 2.5625,夾到 2.4。
        #expect(layout.tabs.map(\.aspectRatio) == [2.4, 0.9, 2.0])
    }

    @Test("切分的 tab:以 pane 矩形的聯集正規化(去掉側欄偏移);shell 是終端機方塊，只在版面出現的 pane 不能開")
    func splitTabNormalizesRectangles() async throws {
        let snapshot = try await Self.snapshot { response in
            Self.editLayouts(&response) { layouts in
                // w2:t1 往右切一半;x 從 26 起(herdr 側欄)。w2:pZ 只出現在版面。
                layouts[3]["panes"] = [
                    ["pane_id": "w2:p1", "focused": false, "rect": Self.rect(26, 0, 82, 32)],
                    ["pane_id": "w2:pZ", "focused": true, "rect": Self.rect(108, 0, 82, 32)],
                ]
                layouts[3]["focused_pane_id"] = "w2:pZ"
            }
        }
        let tab = try #require(SpacesLayout(snapshot: snapshot, workspaceID: "w2")?.tabs.first)

        #expect(tab.blocks == [
            SpacesLayout.Block(
                id: "w2:p1", frame: .init(x: 0, y: 0, width: 0.5, height: 1),
                content: .terminal(program: "scratch"), isFocused: false, target: .terminal(paneID: "w2:p1")
            ),
            SpacesLayout.Block(
                id: "w2:pZ", frame: .init(x: 0.5, y: 0, width: 0.5, height: 1),
                content: .unavailable, isFocused: true, target: nil
            ),
        ])
    }

    @Test("shell 方塊的程式名：pane 名稱 > 終端機標題 > 資料夾最後一段")
    func terminalBlockProgramName() async throws {
        let snapshot = try await Self.snapshot { SnapshotEdit.agent("w2:p1", in: &$0) { $0["terminal_title_stripped"] = "npm run dev" } }

        let block = try #require(SpacesLayout(snapshot: snapshot, workspaceID: "w2")?.tabs.first?.blocks.first)
        #expect(block.content == .terminal(program: "npm run dev"))
    }

    @Test("zoomed 的 tab 只畫聚焦的 pane,佔滿整個分頁")
    func zoomedTabShowsFocusedPaneOnly() async throws {
        let snapshot = try await Self.snapshot { response in
            Self.editLayouts(&response) { layouts in
                layouts[3]["zoomed"] = true
                layouts[3]["focused_pane_id"] = "w2:p1"
                layouts[3]["panes"] = [
                    ["pane_id": "w2:pZ", "focused": false, "rect": Self.rect(0, 0, 82, 32)],
                    ["pane_id": "w2:p1", "focused": true, "rect": Self.rect(82, 0, 82, 32)],
                ]
            }
        }
        let tab = try #require(SpacesLayout(snapshot: snapshot, workspaceID: "w2")?.tabs.first)

        #expect(tab.isZoomed)
        #expect(tab.paneCount == 2)
        #expect(tab.blocks.map(\.id) == ["w2:p1"])
        #expect(tab.blocks.first?.frame == .init(x: 0, y: 0, width: 1, height: 1))
    }

    @Test("只出現在版面的 tab 也列出，順序取 id 的 `:t` 尾碼;沒有名稱")
    func layoutOnlyTabUsesIDSuffix() async throws {
        let snapshot = try await Self.snapshot { response in
            Self.editLayouts(&response) { layouts in
                var extra = layouts[3]
                extra["tab_id"] = "w2:tC"
                extra["panes"] = [["pane_id": "w2:pC", "focused": true, "rect": Self.rect(0, 0, 164, 32)]]
                layouts.append(extra)
            }
        }
        let layout = try #require(SpacesLayout(snapshot: snapshot, workspaceID: "w2"))

        #expect(layout.tabs.map(\.id) == ["w2:t1", "w2:tC"])
        #expect(layout.tabs.last?.number == 12)
        #expect(layout.tabs.last?.label == nil)
    }

    @Test("「需要你」的 agent 方塊狀態是 blocked(含 input_pending)")
    func blockedAgentBlock() async throws {
        let snapshot = try await Self.snapshot { SnapshotEdit.agent("w1:p6", in: &$0) { $0["input_pending"] = true } }

        let block = try #require(SpacesLayout(snapshot: snapshot, workspaceID: "w1")?.tabs.first?.blocks.first)
        #expect(block.content == .agent(name: "Claude Code", detail: "整理植物照片的標籤", status: .blocked))
    }

    @Test("herdr 沒有回報版面時沒有版面圖")
    func noLayoutReported() async throws {
        let missing = try await Self.snapshot { response in
            var result = response["result"] as? [String: Any] ?? [:]
            var snapshot = result["snapshot"] as? [String: Any] ?? [:]
            snapshot["layouts"] = nil
            result["snapshot"] = snapshot
            response["result"] = result
        }
        #expect(SpacesLayout(snapshot: missing, workspaceID: "w1") == nil)

        let otherWorkspaceOnly = try await Self.snapshot { response in
            Self.editLayouts(&response) { layouts in layouts.removeAll { $0["workspace_id"] as? String == "w2" } }
        }
        #expect(SpacesLayout(snapshot: otherWorkspaceOnly, workspaceID: "w2") == nil)
    }
}
