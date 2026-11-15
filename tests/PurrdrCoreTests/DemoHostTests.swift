import Foundation
import PurrdrCore
import PurrdrDemo
import Testing

/// Demo 主機走正式程式路徑：herdr client 對它送的是跟真主機一模一樣的指令。
@Suite("Demo 主機")
struct DemoHostTests {
    @Test("讀 snapshot:Demo 主機有「需要你」、工作中、已完成各一個 Agent")
    func snapshotHasAgentsInEveryGroup() async throws {
        let snapshot = try await HerdrClient(channel: DemoHost()).snapshot()

        #expect(snapshot.version == "0.9.5")
        #expect(snapshot.workspaces == [
            Workspace(id: "w1", number: 1, label: "ledger", activeTabID: "w1:t1"),
            Workspace(id: "w2", number: 2, label: "weather-app", activeTabID: "w2:t1"),
            Workspace(id: "w3", number: 3, label: "notes", activeTabID: "w3:t1"),
        ])
        #expect(snapshot.agents == [
            Agent(paneID: "w1:p1", workspaceID: "w1", kind: "claude", status: .done,
                  terminalTitle: "Tidy up the CSV export", workspaceLabel: "ledger", cwd: "/Users/demo/ledger",
                  session: AgentSessionReference(kind: "id", value: "d3m0d3m0-0000-4000-8000-000000000001"), tabID: "w1:t1"),
            Agent(paneID: "w2:p1", workspaceID: "w2", kind: "claude", status: .blocked,
                  terminalTitle: "Cache the hourly forecast", workspaceLabel: "weather-app", cwd: "/Users/demo/weather-app",
                  session: AgentSessionReference(kind: "id", value: "d3m0d3m0-0000-4000-8000-000000000002"), tabID: "w2:t1"),
            Agent(paneID: "w3:p1", workspaceID: "w3", kind: "codex", status: .working,
                  terminalTitle: "Sync notes to Markdown | notes", workspaceLabel: "notes", cwd: "/Users/demo/notes", tabID: "w3:t1"),
        ])
    }

    @Test("訂閱事件:Demo 主機接受訂閱，之後保持開著(沒有事件)")
    func subscribeStartsAndStaysOpen() async throws {
        let events = try await HerdrClient(channel: DemoHost()).subscribe(EventSubscription.hostWide)
        var iterator = events.makeAsyncIterator()

        #expect(try await iterator.next() == .subscriptionStarted)
        let next = Task { try await iterator.next() }
        try await Task.sleep(for: .milliseconds(50))
        // 串流沒有結束：取消前拿不到下一項。
        next.cancel()
        #expect(try await next.value == nil)
    }

    /// Demo 主機對真正 client 送出的精確指令回應，所以對話畫面走的是正式程式路徑(行為規格 F21)。
    @Test("對話紀錄:Demo 的 Claude Code agent 有可讀的對話(文字、工具串、skill、表格)")
    func claudeAgentsHaveTranscripts() async throws {
        let host = DemoHost()
        let snapshot = try await HerdrClient(channel: host).snapshot()
        let reader = TranscriptReader(channel: host)

        for agent in snapshot.agents where agent.kind == "claude" {
            let sessionID = try #require(agent.claudeSessionID)
            let file = try await reader.locate(sessionID: sessionID, cwd: agent.cwd ?? "")
            let chunk = try await reader.window(path: file.path, endingAt: file.size, lines: 300)
            let items = Conversation.items(from: chunk.lines.flatMap(ClaudeTranscriptParser.messages(in:)))

            #expect(chunk.start == 0)
            #expect(chunk.end == file.size)
            #expect(items.contains { if case .user = $0 { true } else { false } })
            #expect(items.contains { if case .toolRun = $0 { true } else { false } })
            #expect(try await reader.tail(path: file.path, from: file.size) == .unchanged)
        }
        let ledgerFile = try await reader.locate(sessionID: "d3m0d3m0-0000-4000-8000-000000000001", cwd: "/Users/demo/ledger")
        let ledger = try await reader.window(path: ledgerFile.path, endingAt: ledgerFile.size, lines: 300)
        let items = Conversation.items(from: ledger.lines.flatMap(ClaudeTranscriptParser.messages(in:)))
        #expect(items.contains { if case .skill(let skill) = $0 { skill.name == "tdd" } else { false } })
    }

    @Test("列表預覽:Demo 的 Claude Code agent 各有一則預覽")
    func previewsForDemoAgents() async throws {
        let host = DemoHost()
        let snapshot = try await HerdrClient(channel: host).snapshot()
        let requests = snapshot.agents.compactMap { agent in
            agent.claudeSessionID.map { PreviewRequest(key: agent.paneID, sessionID: $0, cwd: agent.cwd ?? "") }
        }

        let previews = try await TranscriptReader(channel: host).previews(of: requests)

        #expect(previews.keys.sorted() == ["w1:p1", "w2:p1"])
    }

    @Test("在場回報:Demo 主機接受 pane.report_metadata")
    func acceptsPresenceReports() async throws {
        try await HerdrClient(channel: DemoHost()).reportPresence(paneID: "w1:p1", model: "Opus 5.5", seq: 1)
    }

    @Test("送出 prompt:Demo 的閒置 agent 收下，對話紀錄接著出現使用者那一行與 agent 的回覆")
    func promptAppendsToDemoTranscript() async throws {
        let host = DemoHost()
        let client = HerdrClient(channel: host)
        let reader = TranscriptReader(channel: host)
        let before = try await reader.locate(sessionID: "d3m0d3m0-0000-4000-8000-000000000001", cwd: "/Users/demo/ledger")

        let outcome = await PromptDelivery(client: client).send("Also add a header row?", to: try #require(try await client.snapshot().agents.first))

        #expect(outcome == .delivered)
        guard case .appended(let chunk) = try await reader.tail(path: before.path, from: before.size) else {
            Issue.record("對話紀錄應接上新的行")
            return
        }
        let items = Conversation.items(from: chunk.lines.flatMap(ClaudeTranscriptParser.messages(in:)))
        guard case .user(let bubble) = items.first else {
            Issue.record("第一則應是使用者訊息")
            return
        }
        #expect(bubble.text == "Also add a header row?")
        #expect(items.count == 2)
        // 新的大小之後，游標再讀就沒有新內容;重新開啟也讀得到。
        let after = try await reader.locate(sessionID: "d3m0d3m0-0000-4000-8000-000000000001", cwd: "/Users/demo/ledger")
        #expect(after.size == chunk.end)
        #expect(try await reader.tail(path: after.path, from: after.size) == .unchanged)
        let window = try await reader.window(path: after.path, endingAt: after.size, lines: 300)
        #expect(window.end == after.size)
    }

    @Test("送出 prompt:Demo 的「需要你」agent 拒絕(agent_blocked),要先回答")
    func blockedDemoAgentNeedsAnswer() async throws {
        let client = HerdrClient(channel: DemoHost())
        let blocked = try #require(try await client.snapshot().agents.first { $0.status == .blocked })

        #expect(await PromptDelivery(client: client).send("Go ahead", to: blocked) == .needsAnswer)
    }

    @Test("中斷:Demo 主機接受按鍵")
    func acceptsKeys() async throws {
        try await HerdrClient(channel: DemoHost()).sendKeys(paneID: "w3:p1", keys: ["esc"])
    }

    @Test("不認得的指令像 shell 一樣以 exit 127 結束")
    func unknownCommandExitsWith127() async throws {
        let session = try await DemoHost().execute("nonexistent-tool --flag")
        var events: [ExecOutput] = []
        for try await event in session.output { events.append(event) }

        #expect(events == [.stderr(Data("sh: nonexistent-tool: command not found\n".utf8)), .exit(code: 127)])
    }

    @Test("PTY:Demo 的 shell 會把輸入回顯出來")
    func ptyEchoesInput() async throws {
        let pty = try await DemoHost().openPTY(PTYRequest(columns: 80, rows: 24))
        var iterator = pty.output.makeAsyncIterator()
        let prompt = try await iterator.next()
        try await pty.write(Data("hi".utf8))
        let echo = try await iterator.next()
        await pty.close()

        #expect(prompt == Data("demo@purrdr ~ % ".utf8))
        #expect(echo == Data("hi".utf8))
    }

    // MARK: - Pane 終端機

    static func text(_ event: PaneTerminalEvent?) -> String {
        guard case .frame(let frame) = event else { return "" }
        return String(decoding: frame.bytes, as: UTF8.self)
    }

    @Test("Pane 終端機:Demo 的 Pane 先送一個 full frame 的 prompt,輸入回顯，控制字元以 ^ 表示")
    func paneTerminalEchoes() async throws {
        let connection = try await PaneTerminalClient(channel: DemoHost()).control(target: "w1:p1", columns: 40, rows: 12)
        var events = connection.events.makeAsyncIterator()

        let first = await events.next()
        guard case .frame(let frame) = first else { Issue.record("第一個事件不是 frame:\(String(describing: first))"); return }
        #expect(frame.full && frame.columns == 40 && frame.rows == 12)
        #expect(Self.text(first).contains("demo@purrdr ledger % "))

        try await connection.send(bytes: Data("hi".utf8))
        #expect(Self.text(await events.next()).contains("hi"))
        try await connection.send(bytes: TerminalKey.character("c").bytes(modifiers: .control))
        #expect(Self.text(await events.next()).contains("^C"))
        try await connection.send(bytes: TerminalKey.escape.bytes())
        #expect(Self.text(await events.next()).contains("^["))

        try await connection.send(.resize(columns: 60, rows: 15))
        guard case .frame(let resized) = await events.next() else { Issue.record("resize 後沒有 frame"); return }
        #expect(resized.full && resized.columns == 60 && resized.rows == 15)

        await connection.release()
        var rest: [PaneTerminalEvent] = []
        while let event = await events.next() { rest.append(event) }
        #expect(rest.last == .closed(.detached))
    }

    @Test("Pane 終端機:「桌機正在操作」情境下，不帶 --takeover 被拒，接管後就能用")
    func paneInUseNeedsTakeover() async throws {
        let client = PaneTerminalClient(channel: DemoHost(scenario: .paneInUse))

        let rejected = try await client.control(target: "w1:p1", columns: 40, rows: 12)
        var events: [PaneTerminalEvent] = []
        for await event in rejected.events { events.append(event) }
        #expect(events == [.closed(.alreadyAttached)])

        let taken = try await client.control(target: "w1:p1", columns: 40, rows: 12, takeover: true)
        var iterator = taken.events.makeAsyncIterator()
        #expect(Self.text(await iterator.next()).contains("demo@purrdr ledger % "))
        await taken.release()
    }

    @Test("Pane 終端機：不存在的 Pane 回 not found")
    func unknownPaneNotFound() async throws {
        let connection = try await PaneTerminalClient(channel: DemoHost()).control(target: "w9:p9", columns: 40, rows: 12)
        var events: [PaneTerminalEvent] = []
        for await event in connection.events { events.append(event) }
        #expect(events == [.closed(.notFound)])
    }

    @Test("Slash 清單:Demo 的 Claude Code agent 有 plugin 宣告的巢狀 skill,停用的 plugin 不出現")
    func slashCatalog() async throws {
        let host = DemoHost()
        let agent = try await HerdrClient(channel: host).snapshot().agents.first { $0.paneID == "w1:p1" }
        let file = try await TranscriptReader(channel: host).locate(sessionID: try #require(agent?.sessionID), cwd: try #require(agent?.cwd))
        let catalog = await ClaudeSlashDiscovery(channel: host).catalog(cwd: agent?.cwd, transcriptPath: file.path)
        #expect(catalog.isComplete)
        #expect(catalog.sections.map(\.source) == [.builtIn, .user, .plugin("demo-kit")])
        #expect(catalog.sections.last?.commands.map(\.name) == ["demo-kit:changelog", "demo-kit:check-diff"])
        #expect(catalog.sections[1].commands.map(\.name) == ["standup", "weekly-summary"])
    }
}
