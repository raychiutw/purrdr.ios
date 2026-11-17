import Foundation
import PurrdrCore
import PurrdrDemo
import PurrdrSSH
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

    // 回歸時(session 不因關閉而結束)不能永遠卡住。
    @Test("對話紀錄一直讀不完的情境：讀對話紀錄的指令不回應，關閉後才結束", .timeLimit(.minutes(1)))
    func pendingTranscriptScenarioNeverAnswers() async throws {
        let session = try await DemoHost(scenario: .transcriptPending).execute(
            TranscriptCommand.locate(
                sessionID: "d3m0d3m0-0000-4000-8000-000000000001",
                projectFolder: ClaudeTranscript.projectFolder(forCWD: "/Users/demo/ledger")))
        let events = Task {
            var events: [ExecOutput] = []
            for try await event in session.output { events.append(event) }
            return events
        }
        try await Task.sleep(for: .milliseconds(50))
        await session.close()

        #expect(try await events.value == [])
    }

    @Test("對話紀錄一直讀不完的情境：只掛住對話畫面的讀取，列表預覽照常回應", .timeLimit(.minutes(1)))
    func pendingTranscriptScenarioStillAnswersPreviews() async throws {
        let host = DemoHost(scenario: .transcriptPending)
        let snapshot = try await HerdrClient(channel: host).snapshot()
        let requests = snapshot.agents.compactMap { agent in
            agent.claudeSessionID.map { PreviewRequest(key: agent.paneID, sessionID: $0, cwd: agent.cwd ?? "") }
        }

        let previews = try await TranscriptReader(channel: host).previews(of: requests)

        #expect(previews.keys.sorted() == ["w1:p1", "w2:p1"])
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

    /// #130:大量輸出情境，ledger 的 agent 一次寫出超過 64 KiB;即時追蹤以分段追趕接著讀，開啟時的追蹤照舊回報落後太多。
    @Test("大量輸出：定位後 agent 一次寫出超過 64 KiB,分段追趕讀得到全部的行")
    func largeOutputIsReadByCatchUp() async throws {
        let host = DemoHost(scenario: .largeOutput(after: .zero))
        let reader = TranscriptReader(channel: host)
        let before = try await reader.locate(sessionID: "d3m0d3m0-0000-4000-8000-000000000001", cwd: "/Users/demo/ledger")

        guard case .tooFarBehind = try await reader.tail(path: before.path, from: before.size) else {
            Issue.record("開啟時的追蹤應回報落後太多")
            return
        }
        guard case .appended(let chunk) = try await reader.catchUp(path: before.path, from: before.size) else {
            Issue.record("分段追趕應讀到新的行")
            return
        }
        #expect(chunk.end - chunk.start > 64 << 10)
        #expect(chunk.lines.count > 300)
        let items = Conversation.items(from: chunk.lines.flatMap(ClaudeTranscriptParser.messages(in:)))
        guard case .agentText(let text) = items.last else {
            Issue.record("最後一則應是 agent 的收尾文字")
            return
        }
        #expect(text.markdown == "I read all 160 export logs; every row exported cleanly.")
        #expect(try await reader.catchUp(path: before.path, from: chunk.end) == .unchanged)
    }

    @Test("圖片：Demo 收下上傳(stdin 到 EOF)回傳上傳資料夾的路徑;送出帶路徑的 prompt 後對話紀錄像 Claude 一樣記成圖片")
    func uploadAndImagePrompt() async throws {
        let host = DemoHost()
        let name = try #require(UploadFileName("mh1a2b3c-k9x2m4p7.jpg"))
        let path = try await ImageUploader(channel: host).upload(Data(count: 200_000), named: name)
        #expect(path == "/Users/demo/.purrdr/uploads/mh1a2b3c-k9x2m4p7.jpg")
        // 大小不符(上傳中斷)時 Demo 也失敗。
        let short = try await host.execute(ImageUploadCommand.posix(name: name, size: 10))
        try await short.write(Data(count: 3))
        await short.closeStdin()
        var exit: Int32?
        for try await case .exit(let code, _) in short.output { exit = code }
        #expect(exit != 0)

        let client = HerdrClient(channel: host)
        let reader = TranscriptReader(channel: host)
        let before = try await reader.locate(sessionID: "d3m0d3m0-0000-4000-8000-000000000001", cwd: "/Users/demo/ledger")
        let prompt = UploadedImages.prompt(text: "What is this?", paths: [path])
        _ = await PromptDelivery(client: client).send(prompt, to: try #require(try await client.snapshot().agents.first))

        guard case .appended(let chunk) = try await reader.tail(path: before.path, from: before.size),
              case .user(let bubble)? = Conversation.items(from: chunk.lines.flatMap(ClaudeTranscriptParser.messages(in:))).first else {
            Issue.record("對話紀錄應接上使用者訊息")
            return
        }
        #expect(bubble.text == "What is this?")
        #expect(bubble.imageCount == 1)
        #expect(bubble.imagePaths == [path])
    }

    @Test("送出 `!` 指令:Demo 的 Claude 不等待就收下，對話紀錄接著出現 shell 交換(輸入行與輸出行)")
    func shellCommandAppendsShellExchange() async throws {
        let host = DemoHost()
        let client = HerdrClient(channel: host)
        let reader = TranscriptReader(channel: host)
        let before = try await reader.locate(sessionID: "d3m0d3m0-0000-4000-8000-000000000001", cwd: "/Users/demo/ledger")

        let outcome = await PromptDelivery(client: client).send("!ls Sources", to: try #require(try await client.snapshot().agents.first))

        #expect(outcome == .submittedCommand)
        guard case .appended(let chunk) = try await reader.tail(path: before.path, from: before.size) else {
            Issue.record("對話紀錄應接上新的行")
            return
        }
        let items = Conversation.items(from: chunk.lines.flatMap(ClaudeTranscriptParser.messages(in:)))
        guard items.count == 1, case .shell(let run) = items[0], case .recorded(let output) = run.output else {
            Issue.record("應該只有一個有輸出的 shell 區塊：\(items)")
            return
        }
        #expect(run.command == "ls Sources")
        #expect(!output.stdout.isEmpty)
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

    /// #44:Demo 的工作中 agent(Codex,`w3:p1`)畫面上有正在寫的散文(即時預覽);停止(一個 Esc)後變完成。
    @Test("工作中:Demo 的 Codex 畫面有即時預覽;停止後變完成、預覽消失;「需要你」的 agent 不會被停止")
    func workingDemoAgentShowsPreviewAndStops() async throws {
        let host = DemoHost()
        let client = HerdrClient(channel: host)
        let screen = try await client.readPane(paneID: "w3:p1")
        #expect(LivePreview.extract(screen: screen) != nil)

        let delivery = PromptDelivery(client: client, sleep: { _ in })
        #expect(await delivery.stop(paneID: "w2:p1") == .needsAnswer)
        #expect(await delivery.stop(paneID: "w3:p1") == .stopped)
        #expect(try await client.snapshot().agents.first { $0.paneID == "w3:p1" }?.status == .done)
        #expect(LivePreview.extract(screen: try await client.readPane(paneID: "w3:p1")) == nil)
        #expect(try await client.snapshot().agents.first { $0.paneID == "w2:p1" }?.status == .blocked)
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

    @Test("Pane 終端機:Demo 的 Pane 有主機端 scrollback,捲動回看先前的輸出，輸入後回到底部")
    func paneTerminalScrollsHostScrollback() async throws {
        let connection = try await PaneTerminalClient(channel: DemoHost()).control(target: "w1:p1", columns: 40, rows: 12)
        var events = connection.events.makeAsyncIterator()
        let first = Self.text(await events.next())
        #expect(first.contains("Wrote export/ledger-2026-11.csv"))
        #expect(!first.contains("Exported row 40 of 60"), "一開始只看得到最後 12 列")

        for _ in 0..<13 {
            try await connection.send(.scroll(.up, column: 0, row: 0))
        }
        // 同尺寸的 resize 一定回一個 full frame:畫出目前的捲動位置，也讓沒捲動時不會一直等。
        try await connection.send(.resize(columns: 40, rows: 12))
        var scrolled = ""
        while case .frame(let frame) = await events.next() {
            scrolled = String(decoding: frame.bytes, as: UTF8.self)
            if frame.full { break }
        }
        #expect(scrolled.contains("Exported row 47 of 60"), "往上捲 13 列要看到先前的輸出:\(scrolled)")
        #expect(!scrolled.contains("Wrote export/ledger-2026-11.csv"), "最後幾列已捲出畫面")

        try await connection.send(bytes: Data("l".utf8))
        let typed = Self.text(await events.next())
        #expect(typed.hasSuffix("demo@purrdr ledger % l"), "輸入把捲動歸位到底部:\(typed)")

        try await connection.send(.scroll(.down, column: 0, row: 0))
        try await connection.send(bytes: Data("s".utf8))
        #expect(Self.text(await events.next()) == "s", "已在底部時往下捲沒有 frame")
        await connection.release()
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

    /// 行為規格 F21:Demo 的 Claude 聊天有已完成的 subagent 與執行中的 workflow,走正式的定位與讀取指令。
    @Test("Demo 的 subagent 與 workflow:卡片、依呼叫 id 找到的 subagent 對話紀錄、執行中的 journal 與其中 agent 的對話紀錄")
    func demoDelegations() async throws {
        let host = DemoHost()
        let reader = TranscriptReader(channel: host)
        let file = try await reader.locate(sessionID: "d3m0d3m0-0000-4000-8000-000000000002", cwd: "/Users/demo/weather-app")
        let chunk = try await reader.window(path: file.path, endingAt: file.size, lines: 300)
        let items = Conversation.items(from: chunk.lines.flatMap(ClaudeTranscriptParser.messages(in:)))
        let subagent = try #require(items.lazy.compactMap { item -> SubagentCard? in if case .subagent(let card) = item { card } else { nil } }.first)
        let workflow = try #require(items.lazy.compactMap { item -> WorkflowCard? in if case .workflow(let card) = item { card } else { nil } }.first)
        #expect(subagent.status == .completed)
        #expect(workflow.status == .running)
        #expect(workflow.name == "forecast-audit")

        let folder = ClaudeTranscript.sessionFolder(ofTranscript: file.path)
        let callID = try #require(subagent.callID)
        let path = try await reader.locateSubagent(sessionFolder: folder, callID: callID)
        let size = try await reader.size(path: path)
        let subagentChunk = try await reader.window(path: path, endingAt: size, lines: 300)
        #expect(!Conversation.items(from: subagentChunk.lines.flatMap(ClaudeTranscriptParser.messages(in:)), showSidechain: true).isEmpty)

        let runID = try #require(workflow.runID)
        guard case .journal(let checksum, let lines) = try await reader.readWorkflow(sessionFolder: folder, runID: runID, knownChecksum: nil) else {
            Issue.record("執行中應讀到 journal")
            return
        }
        let run = WorkflowRun.parse(journal: lines)
        #expect(run.phases.count == 2)
        #expect(try await reader.readWorkflow(sessionFolder: folder, runID: "wf_demo01", knownChecksum: checksum) == .unchanged)

        let agentID = try #require(run.agents.first?.agentID)
        let agentPath = try #require(ClaudeTranscript.workflowAgentTranscript(sessionFolder: folder, runID: "wf_demo01", agentID: agentID))
        let agentSize = try await reader.size(path: agentPath)
        #expect(try await reader.window(path: agentPath, endingAt: agentSize, lines: 300).lines.isEmpty == false)
    }

    @Test("檔案瀏覽:Demo 主機的家目錄與 workspace 資料夾;上傳後出現在清單，同名拒絕")
    func browsesAndUploadsFiles() async throws {
        let folders = HostFolders(channel: DemoHost())

        let home = try await folders.list()
        #expect(home.path == "/Users/demo")
        #expect(home.entries.map(\.name) == ["ledger", "notes", "weather-app", ".zshrc", "README.md"])
        let ledger = try await folders.list("/Users/demo/ledger")
        #expect(ledger.entries.map(\.name) == ["reports", "export.csv", "ledger.py"])
        await #expect {
            _ = try await folders.list("/Users/demo/missing")
        } throws: { error in
            if case HostFolderError.cannotOpen = error { return true }
            return false
        }

        let path = try await folders.upload(Data("hello".utf8), named: "todo.txt", to: "/Users/demo/notes")
        #expect(path == "/Users/demo/notes/todo.txt")
        let notes = try await folders.list("/Users/demo/notes")
        #expect(notes.entries.first { $0.name == "todo.txt" }?.size == 5)
        await #expect(throws: HostFolderError.alreadyExists) {
            _ = try await folders.upload(Data("again".utf8), named: "todo.txt", to: "/Users/demo/notes")
        }
    }

    @Test("檔案上傳:Demo 主機認得 gzip 傳輸的指令，收到傳輸大小的 bytes 就成功，清單顯示原始大小")
    func acceptsGzipUploadCommand() async throws {
        let host = DemoHost()
        let session = try await host.execute(
            HostFolderCommand.upload(folder: "/Users/demo/notes", name: "build.log", size: 1_000, encoding: .gzip, transferSize: 21))
        try await session.write(Data(count: 21))
        await session.closeStdin()
        let output = try await session.collectOutput()

        #expect(output.exitCode == 0)
        #expect(output.stdoutText == "/Users/demo/notes/build.log\n")
        let notes = try await HostFolders(channel: host).list("/Users/demo/notes")
        #expect(notes.entries.first { $0.name == "build.log" }?.size == 1_000)
    }

    @Test("登入 Shell:Demo 主機開回顯的 shell")
    func opensLoginShell() async throws {
        let pty = try await DemoHost().openPTY(PTYRequest(columns: 80, rows: 24))
        var iterator = pty.output.makeAsyncIterator()
        #expect(try await iterator.next() == Data("demo@purrdr ~ % ".utf8))
    }
}

/// Demo 情境:Tailscale SSH check mode(UI 測試用)。
@Suite("Demo 主機:Tailscale check mode")
struct DemoHostTailscaleCheckTests {
    @Test("第一個指令先要求驗證，驗證完自動繼續;之後的指令不再要求")
    func checkThenContinue() async throws {
        let prompts = PromptLog()
        let host = DemoHost(scenario: .tailscaleCheck(completesAfter: .milliseconds(200)), tailscaleCheck: prompts.observe)

        _ = try await HerdrClient(channel: host).snapshot()
        _ = try await HerdrClient(channel: host).snapshot()

        #expect(prompts.urls == [DemoHost.tailscaleCheckURL, nil])
    }

    @Test("等待驗證時取消：指令以「已取消」結束")
    func cancelCheck() async throws {
        let prompts = PromptLog()
        let host = DemoHost(scenario: .tailscaleCheck(completesAfter: nil), tailscaleCheck: prompts.observe)

        let pending = Task { try await HerdrClient(channel: host).snapshot() }
        try await prompts.firstPrompt().cancel()

        await #expect(throws: SSHConnectionError.tailscaleCheckCancelled) { _ = try await pending.value }
        #expect(prompts.urls == [DemoHost.tailscaleCheckURL, nil])
    }
}
