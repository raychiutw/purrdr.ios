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
            Workspace(id: "w1", number: 1, label: "ledger"),
            Workspace(id: "w2", number: 2, label: "weather-app"),
            Workspace(id: "w3", number: 3, label: "notes"),
        ])
        #expect(snapshot.agents == [
            Agent(paneID: "w1:p1", workspaceID: "w1", kind: "claude", status: .done,
                  terminalTitle: "Tidy up the CSV export", workspaceLabel: "ledger", cwd: "/Users/demo/ledger"),
            Agent(paneID: "w2:p1", workspaceID: "w2", kind: "claude", status: .blocked,
                  terminalTitle: "Cache the hourly forecast", workspaceLabel: "weather-app", cwd: "/Users/demo/weather-app"),
            Agent(paneID: "w3:p1", workspaceID: "w3", kind: "codex", status: .working,
                  terminalTitle: "Sync notes to Markdown | notes", workspaceLabel: "notes", cwd: "/Users/demo/notes"),
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
}
