import Foundation
import PurrdrCore
import PurrdrDemo
import Testing

/// Demo 主機走正式程式路徑：herdr client 對它送的是跟真主機一模一樣的指令。
@Suite("Demo 主機")
struct DemoHostTests {
    @Test("讀 snapshot:Demo 主機有一個 Claude Code 的 Agent")
    func snapshotHasOneClaudeAgent() async throws {
        let snapshot = try await HerdrClient(channel: DemoHost()).snapshot()

        #expect(snapshot.version == "0.9.5")
        #expect(snapshot.agents == [
            Agent(paneID: "w1:p1", workspaceID: "w1", kind: "claude", status: .done,
                  terminalTitle: "Tidy up the CSV export", workspaceLabel: "ledger", cwd: "/Users/demo/ledger"),
        ])
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
