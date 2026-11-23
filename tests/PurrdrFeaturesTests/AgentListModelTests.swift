import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

@MainActor
@Suite("Agent 列表")
struct AgentListModelTests {
    static let bridge = HerdrCommand.bridge()

    /// 讀一次 snapshot 後的 model。`modify` 以錄製回應為底改動測試關心的值。
    static func loadedModel(modify: ((inout [String: Any]) -> Void)? = nil) async -> AgentListModel {
        let host = FakeHost()
        let reply: FakeReply = modify.map { .recorded("session.snapshot.ndjson", modify: $0) } ?? .recorded("session.snapshot.ndjson")
        await host.expect(bridge, reply: reply)
        let model = AgentListModel(client: HerdrClient(channel: host))
        await model.load()
        return model
    }

    static func row(_ paneID: String, in model: AgentListModel) -> AgentRow? {
        model.sections.flatMap(\.rows).first { $0.paneID == paneID }
    }

    @Test("載入後依 Agent 狀態分組：工作中在閒置之前，每列有標題、副標、預覽與時間")
    func groupsAgentsByStatus() async {
        let model = await Self.loadedModel()

        #expect(model.phase == .loaded)
        #expect(model.sections == [
            AgentSection(group: .working, rows: [
                AgentRow(paneID: "w1:pA", title: "規劃天氣小工具", workspace: "garden-journal", subtitle: "garden-journal · Claude Code · demo/Projects",
                         preview: .none, time: .now, status: .working, tabName: "Tab 2"),
                AgentRow(paneID: "w1:pB", title: "重構食譜匯入", workspace: "garden-journal", subtitle: "garden-journal · Claude Code · Projects/recipe-box",
                         preview: .none, time: .now, status: .working, tabName: "Tab 3"),
            ]),
            AgentSection(group: .idle, rows: [
                // workspace 名稱就是資料夾最後一段，已經顯示在資料夾裡，不重複。
                AgentRow(paneID: "w1:p6", title: "整理植物照片的標籤", workspace: "garden-journal", subtitle: "Claude Code · Projects/garden-journal",
                         preview: .none, time: nil, status: .idle, tabName: "Tab 1"),
            ]),
        ])
    }

    @Test("blocked 的 Agent 在「需要你」,預覽是「等待你的輸入」")
    func blockedAgentNeedsYou() async {
        let model = await Self.loadedModel { SnapshotEdit.agent("w1:p6", in: &$0) { $0["agent_status"] = "blocked" } }

        #expect(model.sections.map(\.group) == [.needsYou, .working])
        #expect(model.sections.first?.rows.map(\.paneID) == ["w1:p6"])
        #expect(Self.row("w1:p6", in: model)?.preview == .needsInput)
        #expect(Self.row("w1:p6", in: model)?.status == .blocked)
    }

    @Test("idle 但 input_pending 的 Agent 也算「需要你」;working 中的 input_pending 不算")
    func inputPendingIdleAgentNeedsYou() async {
        let model = await Self.loadedModel {
            SnapshotEdit.agent("w1:p6", in: &$0) { $0["input_pending"] = true }
            SnapshotEdit.agent("w1:pA", in: &$0) { $0["input_pending"] = true }
        }

        #expect(model.sections.map(\.group) == [.needsYou, .working])
        #expect(model.sections.first?.rows.map(\.paneID) == ["w1:p6"])
        #expect(Self.row("w1:p6", in: model)?.status == .blocked)
        #expect(Self.row("w1:pA", in: model)?.status == .working)
    }

    @Test("「需要你」與「工作中」依主機上的 workspace 順序排列")
    func ordersByWorkspaceNumber() async {
        let model = await Self.loadedModel {
            SnapshotEdit.workspace("w1", in: &$0) { $0["number"] = 3 }
            SnapshotEdit.agent("w1:pB", in: &$0) { $0["workspace_id"] = "w2" }
        }

        #expect(model.sections.first { $0.group == .working }?.rows.map(\.paneID) == ["w1:pB", "w1:pA"])
    }

    @Test("Agents 列第一行是 workspace 名稱(#269,原型 B):人取的名稱或 herdr 的 workspace 名稱;不受 agent 名稱、session 標題影響")
    func rowShowsWorkspaceName() async {
        let model = await Self.loadedModel {
            SnapshotEdit.agent("w1:p6", in: &$0) { $0["name"] = "植物管家" }
            SnapshotEdit.agent("w1:pA", in: &$0) { $0["workspace_id"] = "w2" }
            SnapshotEdit.workspace("w2", in: &$0) { $0["label"] = "天氣" }
        }

        #expect(Self.row("w1:p6", in: model)?.workspace == "garden-journal", "agent 名稱不取代 workspace 名稱")
        #expect(Self.row("w1:pA", in: model)?.workspace == "天氣")
    }

    @Test("Agents 列第一行：workspace 沒有名稱時退回資料夾最後一段，再沒有才是 workspace id")
    func rowWorkspaceNameFallsBack() {
        let inFolder = Agent(paneID: "w9:p1", workspaceID: "w9", kind: "claude", status: .idle, cwd: "/Users/demo/Projects/ledger")
        #expect(AgentRowText.workspaceName(for: inFolder) == "ledger")
        let windows = Agent(paneID: "w9:p1", workspaceID: "w9", kind: "claude", status: .idle, cwd: #"C:\Users\demo\notes"#)
        #expect(AgentRowText.workspaceName(for: windows) == "notes")
        let bare = Agent(paneID: "w9:p1", workspaceID: "w9", kind: "claude", status: .idle)
        #expect(AgentRowText.workspaceName(for: bare) == "w9")
        let blankLabel = Agent(paneID: "w9:p1", workspaceID: "w9", kind: "claude", status: .idle, workspaceLabel: " ", cwd: "/srv/site")
        #expect(AgentRowText.workspaceName(for: blankLabel) == "site")
    }

    @Test("標題：herdr agent 名稱優先")
    func titlePrefersAgentName() async {
        let model = await Self.loadedModel { SnapshotEdit.agent("w1:p6", in: &$0) { $0["name"] = "植物管家" } }

        #expect(Self.row("w1:p6", in: model)?.title == "植物管家")
    }

    @Test("標題：單一 agent 的 workspace,人取的名稱(不等於資料夾名)優先於 session 標題")
    func titlePrefersHumanWorkspaceLabelForSingleAgentWorkspace() async {
        let model = await Self.loadedModel {
            SnapshotEdit.agent("w1:pA", in: &$0) { $0["workspace_id"] = "w2" }
            SnapshotEdit.workspace("w2", in: &$0) { $0["label"] = "天氣" }
        }

        #expect(Self.row("w1:pA", in: model)?.title == "天氣")
        // 多 agent 的 workspace 名稱等於資料夾名(garden-journal),不算人取的。
        #expect(Self.row("w1:p6", in: model)?.title == "整理植物照片的標籤")
    }

    @Test("標題：預設終端機標題與像 session id 的字串不當標題，退回 workspace 名稱")
    func titleSkipsDefaultTerminalTitles() async {
        let model = await Self.loadedModel {
            SnapshotEdit.agent("w1:pA", in: &$0) { $0["terminal_title_stripped"] = "Claude Code" }
            SnapshotEdit.agent("w1:pB", in: &$0) { $0["terminal_title_stripped"] = "claude --resume 3f2a9c1e-77b0-4c2d-9a51-0d6e4b8f1a22" }
            SnapshotEdit.agent("w1:p6", in: &$0) { $0["terminal_title_stripped"] = "3f2a9c1e-77b0-4c2d-9a51-0d6e4b8f1a22" }
        }

        #expect(Self.row("w1:pA", in: model)?.title == "garden-journal")
        #expect(Self.row("w1:pB", in: model)?.title == "garden-journal")
        #expect(Self.row("w1:p6", in: model)?.title == "garden-journal")
    }

    @Test("同一 workspace 中沒有自己標題的 agent,副標附序號")
    func ordinalForAgentsWithoutOwnTitle() async {
        let model = await Self.loadedModel {
            SnapshotEdit.agent("w1:pA", in: &$0) { $0["terminal_title_stripped"] = "Claude Code" }
        }

        // w1 有三個 agent,pA 是 snapshot 中的第 2 個。
        #expect(Self.row("w1:pA", in: model)?.subtitle == "2 of 3 · Claude Code · demo/Projects")
    }

    @Test("標題：Claude 的 session 標題用 title,沒有才用終端機標題")
    func claudeSessionTitleFromTitleField() async {
        let model = await Self.loadedModel { SnapshotEdit.agent("w1:pA", in: &$0) { $0["title"] = "天氣小工具 v2" } }

        #expect(Self.row("w1:pA", in: model)?.title == "天氣小工具 v2")
    }

    @Test("標題：Codex 的名稱在終端機標題「 | 」之前;沒有「 | 」是預設標題")
    func codexSessionTitleFromTerminalTitle() async {
        let model = await Self.loadedModel {
            SnapshotEdit.agent("w1:pA", in: &$0) {
                $0["agent"] = "codex"
                $0["title"] = "幫我看一下這個天氣 API 為什麼"
                $0["terminal_title_stripped"] = "天氣 API 除錯 | Projects"
            }
            SnapshotEdit.agent("w1:pB", in: &$0) {
                $0["agent"] = "codex"
                $0["terminal_title_stripped"] = "codex"
            }
        }

        #expect(Self.row("w1:pA", in: model)?.title == "天氣 API 除錯")
        #expect(Self.row("w1:pA", in: model)?.subtitle == "garden-journal · Codex · demo/Projects")
        #expect(Self.row("w1:pB", in: model)?.title == "garden-journal")
    }

    @Test("搜尋：不分大小寫比對標題、agent 種類與顯示名、資料夾、workspace 名稱")
    func searchFiltersRows() async {
        let model = await Self.loadedModel { SnapshotEdit.agent("w1:pB", in: &$0) { $0["agent"] = "agy" } }

        model.query = "RECIPE"
        #expect(model.sections.flatMap(\.rows).map(\.paneID) == ["w1:pB"])

        model.query = "antigravity"  // herdr 叫 agy,顯示名是 Antigravity
        #expect(model.sections.flatMap(\.rows).map(\.paneID) == ["w1:pB"])

        model.query = "天氣"
        #expect(model.sections.flatMap(\.rows).map(\.paneID) == ["w1:pA"])

        model.query = "Garden-Journal"  // workspace 名稱
        #expect(model.sections.flatMap(\.rows).count == 3)

        model.query = "沒有這個"
        #expect(model.sections.isEmpty)
        #expect(model.hasAgents)

        model.query = "  "
        #expect(model.sections.flatMap(\.rows).count == 3)
    }

    @Test("有最後一則訊息時，預覽顯示訊息與時間;自己的訊息前綴「你」;blocked 仍顯示等待輸入")
    func messagePreviewAndTime() async {
        let model = await Self.loadedModel()
        let sent = Date(timeIntervalSince1970: 1_700_000_000)

        model.previews = [
            "w1:p6": MessagePreview(text: "標籤都整理好了", date: sent, isFromUser: false),
            "w1:pB": MessagePreview(text: "順便加上單元測試", date: sent, isFromUser: true),
        ]

        #expect(Self.row("w1:p6", in: model)?.preview == .message("標籤都整理好了", fromYou: false))
        #expect(Self.row("w1:p6", in: model)?.time == .date(sent))
        #expect(Self.row("w1:pB", in: model)?.preview == .message("順便加上單元測試", fromYou: true))
        // working 時右欄是「現在」,不是訊息時間。
        #expect(Self.row("w1:pB", in: model)?.time == .now)
    }

    @Test("閒置依最後訊息時間新→舊，沒有時間的排最後")
    func idleOrderedByLastMessageTime() async {
        let model = await Self.loadedModel {
            SnapshotEdit.agent("w1:pA", in: &$0) { $0["agent_status"] = "done" }
            SnapshotEdit.agent("w1:pB", in: &$0) { $0["agent_status"] = "idle" }
        }

        model.previews = [
            "w1:pA": MessagePreview(text: "舊的", date: Date(timeIntervalSince1970: 1_000), isFromUser: false),
            "w1:pB": MessagePreview(text: "新的", date: Date(timeIntervalSince1970: 2_000), isFromUser: false),
        ]

        #expect(model.sections.map(\.group) == [.idle])
        #expect(model.sections.first?.rows.map(\.paneID) == ["w1:pB", "w1:pA", "w1:p6"])
    }

    @Test("主機回錯誤時，列表顯示 herdr 的原文而不是原始 JSON")
    func showsHerdrMessageOnFailure() async {
        let host = FakeHost()
        await host.expect(Self.bridge, reply: .recorded("error.invalid-request.ndjson"))
        let model = AgentListModel(client: HerdrClient(channel: host))

        await model.load()

        #expect(model.phase == .failed("invalid request: key must be a string at line 1 column 56"))
        #expect(model.sections.isEmpty)
    }

    /// 預覽與時間來自對話紀錄(§4.7);fixture 是從真實 Claude Code 對話紀錄擷取的。
    @Test("預覽：讀完 snapshot 後以一次往返讀對話紀錄檔尾，列顯示最後一則訊息與時間")
    func previewsComeFromTranscripts() async throws {
        let shell = try LocalShellHost.temporary()
        try shell.write(Fixtures.transcript(), to: ".claude/projects/-Users-demo-Projects-garden-journal/00000000-0000-0000-0000-000000000001.jsonl")
        let host = RoutingHost(shell: shell)
        await host.bridge.expect(Self.bridge, reply: .recorded("session.snapshot.ndjson"))
        let model = AgentListModel(client: HerdrClient(channel: host), transcripts: TranscriptReader(channel: host))

        await model.load()

        let row = try #require(Self.row("w1:p6", in: model))
        guard case .message(let text, let fromYou) = row.preview else {
            Issue.record("w1:p6 沒有預覽：\(row.preview)")
            return
        }
        #expect(text.hasPrefix("CSV 匯出整理好了 ✅"))
        #expect(fromYou == false)
        guard case .date(let date) = row.time else {
            Issue.record("w1:p6 沒有訊息時間")
            return
        }
        // fixture 最後一則 agent 文字的時間戳 2026-11-13T23:59:52.797Z。
        #expect(abs(date.timeIntervalSince1970 - 1_794_614_392.797) < 0.001)
        #expect(await host.shellCommands.count == 1)
    }

    /// R-I04:預覽帶讀取時的 session;session 改變(herdr 回收 pane 給新聊天)就丟，不顯示舊聊天的最後一行。
    @Test("預覽：pane 的 session 改變後不再顯示舊 session 的預覽")
    func previewIsDroppedWhenSessionChanges() async throws {
        let shell = try LocalShellHost.temporary()
        try shell.write(Fixtures.transcript(), to: ".claude/projects/-Users-demo-Projects-garden-journal/00000000-0000-0000-0000-000000000001.jsonl")
        let host = RoutingHost(shell: shell)
        await host.bridge.expect(Self.bridge, reply: .recorded("session.snapshot.ndjson"))
        await host.bridge.expect(Self.bridge, reply: .recorded("session.snapshot.ndjson") {
            SnapshotEdit.agent("w1:p6", in: &$0) {
                $0["agent_session"] = ["source": "herdr:claude", "agent": "claude", "kind": "id", "value": "00000000-0000-0000-0000-0000000000cc"]
            }
        })
        let model = AgentListModel(client: HerdrClient(channel: host), transcripts: TranscriptReader(channel: host))
        await model.load()
        #expect(Self.row("w1:p6", in: model)?.preview != Optional(.none))

        await model.load()

        // 沒有預覽時不顯示狀態字(列尾的狀態標籤已經有，#35:不重複出現兩次)。
        #expect(Self.row("w1:p6", in: model)?.preview == AgentRow.Preview.none)
    }
}
