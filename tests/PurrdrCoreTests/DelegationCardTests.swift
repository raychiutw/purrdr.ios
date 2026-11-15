import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// Subagent 與 workflow 卡片的狀態判定(行為規格 F10「Subagent 卡」「狀態判定」、§4.6「任務通知」「Hand-back」、R-W01)。
///
/// 解析的對象是 `Fixtures/claude-code/delegation.jsonl`:從作者 Mac 上真實 Claude Code 2.1.317–2.1.325 對話紀錄擷取、
/// 去識別化的 8 行(結構、旗標、harness 固定句子原樣，文字與 id 換成假值,見 `Fixtures/README.md`):
///
/// | 行 | 內容 |
/// |---|---|
/// | 0 | 背景 `Agent` 呼叫(`run_in_background`,id `toolu_demo_d01`) |
/// | 1 | 它的啟動結果「Async agent launched…agentId: ad3e0000000000001」 |
/// | 2 | harness 寫的任務通知(`origin.kind` task-notification,有 tool-use-id) |
/// | 3 | 前景 `Agent` 呼叫(web-fetch,id `toolu_demo_d02`) |
/// | 4 | 它的結果(hand-back 框 + `<usage>`) |
/// | 5、6 | `SendMessage` 給背景 agent 與結果(`resumedAgentId`) |
/// | 7 | 排隊中的任務通知(`queued_command`,只有 task-id、沒有 tool-use-id) |
@Suite("Subagent 與 workflow 卡片")
struct DelegationCardTests {
    static let lines = Fixtures.transcriptLines("delegation.jsonl")
    static let backgroundAgent = "ad3e0000000000001"

    static func items(_ lines: [String]) -> [ConversationItem] {
        Conversation.items(from: lines.flatMap(ClaudeTranscriptParser.messages(in:)))
    }

    static func cards(_ indices: [Int], extra: [String] = []) -> [SubagentCard] {
        items(indices.map { lines[$0] } + extra).compactMap { item in
            if case .subagent(let card) = item { return card }
            return nil
        }
    }

    static func card(_ indices: [Int], extra: [String] = []) -> SubagentCard? {
        cards(indices, extra: extra).first
    }

    /// 改第 `index` 行，並換一個 uuid(當作另一行)。
    static func line(_ index: Int, uuid: String? = nil, _ modify: (inout [String: Any]) -> Void) -> String {
        Fixtures.transcriptLine(index, of: "delegation.jsonl") { object in
            if let uuid { object["uuid"] = uuid }
            modify(&object)
        }
    }

    /// 改任務通知(第 2 行)的文字。
    static func notification(uuid: String, _ change: (String) -> String) -> String {
        line(2, uuid: uuid) { object in
            var message = object["message"] as? [String: Any] ?? [:]
            message["content"] = change(message["content"] as? String ?? "")
            object["message"] = message
        }
    }

    // MARK: - 前景

    @Test("前景 subagent 卡：標題是 description,說明行是 subagent_type;結果到達後完成，時長 = 結果時間 − 呼叫時間，tokens 與工具數取自結果")
    func foregroundCardCompletesWithResult() throws {
        let card = try #require(Self.card([3, 4]))

        #expect(card.title == "Check the export docs for broken links")
        #expect(card.agentType == "web-fetch")
        #expect(card.status == .completed)
        #expect(card.isBackground == false)
        // 06:40:08.050 − 06:39:00.024
        #expect(abs((card.duration ?? 0) - 68.026) < 0.001)
        #expect(card.tokens == 114_586)
        #expect(card.toolCalls == 12)
        #expect(card.agentID == "ad3e0000000000004")
        // 結果是 hand-back 框中「The report follows:」之後、去掉兩格縮排的報告，不含之後的 agentId 與 usage。
        #expect(card.result == "## Result\n\nTwo links are broken:\n- `docs/export.md` line 12 points to a renamed page.\n- `docs/import.md` line 40 has a typo in the anchor.")
    }

    @Test("前景 subagent 卡：結果到達前是執行中，沒有時長")
    func foregroundCardRunsUntilResult() throws {
        let card = try #require(Self.card([3]))

        #expect(card.status == .running)
        #expect(card.duration == nil)
        #expect(card.result == nil)
    }

    @Test("前景 subagent 卡：結果是錯誤就是失敗")
    func foregroundErrorFails() throws {
        // 改動：第 4 行的 tool_result 加上 is_error(真實資料裡沒有失敗的 Agent 結果)。
        let failed = Self.line(4) { object in
            var message = object["message"] as? [String: Any] ?? [:]
            var blocks = message["content"] as? [[String: Any]] ?? []
            blocks[0]["is_error"] = true
            message["content"] = blocks
            object["message"] = message
        }
        let card = try #require(Self.card([3], extra: [failed]))

        #expect(card.status == .failed)
    }

    @Test("沒有 description 時標題是「Agent」")
    func untitledCardIsAgent() throws {
        // 改動：拿掉第 3 行呼叫輸入的 description。
        let untitled = Self.line(3) { object in
            var message = object["message"] as? [String: Any] ?? [:]
            var blocks = message["content"] as? [[String: Any]] ?? []
            var input = blocks[0]["input"] as? [String: Any] ?? [:]
            input["description"] = nil
            blocks[0]["input"] = input
            message["content"] = blocks
            object["message"] = message
        }
        let card = try #require(Self.items([untitled]).compactMap { item -> SubagentCard? in
            if case .subagent(let card) = item { return card }
            return nil
        }.first)

        #expect(card.title == "Agent")
    }

    @Test("卡片自成一列：不併入工具串，也不算進工具串摘要;任務通知不產生列")
    func cardsAreOwnRows() {
        let kinds = Self.items(Self.lines).map { item -> String in
            switch item {
            case .subagent(let card): "subagent \(card.callID ?? "")"
            case .workflow: "workflow"
            case .toolRun(let run): "tools \(run.steps.count) \(run.summary.otherTools)"
            case .user: "user"
            case .agentText: "agent"
            case .skill: "skill"
            case .note: "note"
            }
        }

        #expect(kinds == ["subagent toolu_demo_d01", "subagent toolu_demo_d02", "tools 1 1"])
    }

    // MARK: - 背景

    /// R-W01:背景 agent 卡曾經全部立刻顯示完成。
    @Test("背景 subagent 卡：啟動結果(Async agent launched)不算結束，記下 agent id,仍是執行中")
    func backgroundLaunchKeepsRunning() throws {
        let card = try #require(Self.card([0, 1]))

        #expect(card.status == .running)
        #expect(card.isBackground)
        #expect(card.agentID == Self.backgroundAgent)
        #expect(card.result == nil)
    }

    @Test("背景 subagent 卡：harness 寫的任務通知到達才結束;tokens、工具數、時長與結果取自通知")
    func backgroundCompletesOnNotification() throws {
        let card = try #require(Self.card([0, 1, 2]))

        #expect(card.status == .completed)
        #expect(card.tokens == 64882)
        #expect(card.toolCalls == 15)
        #expect(card.duration == 66.01)
        #expect(card.result == "Use the streaming parser: it handles quoted commas and is twice as fast on large files.")
    }

    /// commit 10b7fe8:使用者貼上的同樣區塊仍是使用者訊息。
    @Test("使用者打的行裡的任務通知不算：卡片仍是執行中，那行是使用者泡泡")
    func pastedNotificationIsUserMessage() throws {
        // 改動：拿掉第 2 行的 harness 標記(origin、promptSource),變成使用者打的行。
        let pasted = Self.line(2) { object in
            object["origin"] = nil
            object["promptSource"] = nil
        }
        let items = Self.items([Self.lines[0], Self.lines[1], pasted])

        guard case .subagent(let card) = items.first else {
            Issue.record("第一列應是 subagent 卡")
            return
        }
        #expect(card.status == .running)
        guard case .user(let bubble) = items.last else {
            Issue.record("貼上的通知應是使用者泡泡")
            return
        }
        #expect(bubble.text.hasPrefix("<task-notification>"))
    }

    @Test("通知狀態 failed／killed／error／cancelled 都是失敗", arguments: ["failed", "killed", "error", "cancelled"])
    func failedStatuses(status: String) throws {
        let failed = Self.notification(uuid: "00000000-0000-4000-9000-0000000000a1") {
            $0.replacingOccurrences(of: "<status>completed</status>", with: "<status>\(status)</status>")
        }
        let card = try #require(Self.card([0, 1], extra: [failed]))

        #expect(card.status == .failed)
    }

    @Test("同一個 agent 有多則通知時以最新一則為準")
    func latestNotificationWins() throws {
        let failed = Self.notification(uuid: "00000000-0000-4000-9000-0000000000a2") {
            $0.replacingOccurrences(of: "<status>completed</status>", with: "<status>failed</status>")
        }

        #expect(Self.card([0, 1, 2], extra: [failed])?.status == .failed)
        #expect(Self.card([0, 1], extra: [failed, Self.lines[2]])?.status == .completed)
    }

    @Test("SendMessage 的結果帶 resumedAgentId 時卡片變回執行中，直到下一則通知(依 task id 對應，沒有 tool-use-id 也行)")
    func resumedAgentRunsUntilNextReport() throws {
        let resumed = try #require(Self.card([0, 1, 2, 5, 6]))
        #expect(resumed.status == .running)

        let reported = try #require(Self.card([0, 1, 2, 5, 6, 7]))
        #expect(reported.status == .completed)
        #expect(reported.result == "The streaming parser also uses a third of the memory.")
        #expect(reported.tokens == 287_857)
    }

    @Test("回報內容優先取 hand-back 訊息，其次才是通知的 result")
    func handBackPreferred() throws {
        // 改動：以第 2 行為底，做成 2.1.294 起的 peer hand-back(`origin {kind:peer, from, handback:true, body}`)。
        // 本機的對話紀錄沒有這種行，形狀依行為規格 §4.6。
        let handBack = Self.line(2, uuid: "00000000-0000-4000-9000-0000000000a3") { object in
            object["origin"] = [
                "kind": "peer", "from": Self.backgroundAgent, "handback": true,
                "body": "[Subagent hand-back] The text below is the final report. The report follows:\n  Pick the streaming parser.\n  It is faster.",
            ]
            var message = object["message"] as? [String: Any] ?? [:]
            message["content"] = "[Subagent hand-back] The text below is the final report. The report follows:\n  Pick the streaming parser.\n  It is faster."
            object["message"] = message
        }
        let card = try #require(Self.card([0, 1], extra: [handBack, Self.lines[2]]))

        #expect(card.status == .completed)
        #expect(card.result == "Pick the streaming parser.\nIt is faster.")
    }

    // MARK: - Workflow

    /// 本機沒有 `Workflow` 工具的對話紀錄:以第 3、4 行為底改成 workflow 呼叫與啟動結果(形狀依行為規格 F10、§4.6)。
    static func workflowCall(_ input: [String: Any]) -> String {
        line(3) { object in
            var message = object["message"] as? [String: Any] ?? [:]
            var blocks = message["content"] as? [[String: Any]] ?? []
            blocks[0]["name"] = "Workflow"
            blocks[0]["input"] = input
            message["content"] = blocks
            object["message"] = message
        }
    }

    static let workflowLaunched = line(4) { object in
        var message = object["message"] as? [String: Any] ?? [:]
        message["content"] = [["tool_use_id": "toolu_demo_d02", "type": "tool_result", "content": [["type": "text", "text": "Workflow launched in the background.\nRun ID: wf_demo01\nYou will be notified when it finishes."]]]]
        object["message"] = message
        object["toolUseResult"] = nil
    }

    static func workflowCard(_ lines: [String]) -> WorkflowCard? {
        items(lines).compactMap { item -> WorkflowCard? in
            if case .workflow(let card) = item { return card }
            return nil
        }.first
    }

    @Test("Workflow 卡：名稱與說明取自腳本的 meta 區塊;啟動結果(Workflow launched)記下 run id,仍是執行中")
    func workflowNameFromScriptMeta() throws {
        let call = Self.workflowCall(["script": "export const meta = {\n  name: 'release-review',\n  description: \"Check the release, then review its wording\",\n}\nexport default async function run() {}"])
        let card = try #require(Self.workflowCard([call, Self.workflowLaunched]))

        #expect(card.name == "release-review")
        #expect(card.detail == "Check the release, then review its wording")
        #expect(card.runID == "wf_demo01")
        #expect(card.status == .running)
    }

    @Test("Workflow 卡：沒有 meta 時名稱取自 scriptPath 的 <name>-wf_<run>.js,都沒有就是「Workflow」")
    func workflowNameFallbacks() {
        let fromPath = Self.workflowCall(["scriptPath": "/Users/demo/.claude/workflows/nightly-check-wf_demo01.js"])
        #expect(Self.workflowCard([fromPath])?.name == "nightly-check")
        #expect(Self.workflowCard([Self.workflowCall([:])])?.name == "Workflow")
    }

    @Test("Workflow 卡：之後的任務通知(依呼叫 id)才結束")
    func workflowCompletesOnNotification() throws {
        let call = Self.workflowCall(["scriptPath": "/Users/demo/.claude/workflows/nightly-check-wf_demo01.js"])
        let done = Self.notification(uuid: "00000000-0000-4000-9000-0000000000a4") {
            $0.replacingOccurrences(of: "toolu_demo_d01", with: "toolu_demo_d02")
                .replacingOccurrences(of: "<task-id>\(Self.backgroundAgent)</task-id>", with: "<task-id>wf_demo01</task-id>")
        }
        let card = try #require(Self.workflowCard([call, Self.workflowLaunched, done]))

        #expect(card.status == .completed)
        #expect(card.tokens == 64882)
    }
}
