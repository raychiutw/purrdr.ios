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
}
