import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrSSH
import PurrdrTestSupport
import Testing

/// 新增聊天續接過去的 session(#309,spec #298):資料夾的清單第一列是「新的聊天」,其餘是 session,勾號只有一個。
@MainActor
@Suite("新增聊天:續接 session")
struct NewChatResumeTests {
    static func line(_ json: String) -> Data { Data(json.utf8) + [0x0A] }

    static let sessionsReply = line(
        #"{"id":"purrdr:sessions.list","result":{"type":"sessions_list","sessions":[{"id":"48b84c34-58a1-465f-94b2-370ed0699957","modified":"2026-11-20T15:02:11Z","summary":"Add a daily watering reminder to README.md"},{"id":"0b9e6f1c-2d4a-4c8e-9f00-5a1b2c3d4e5f","modified":"2026-11-19T09:40:03Z"}]}}"#)
    static let created = line(
        #"{"id":"purrdr:workspace.create","result":{"type":"workspace_created","workspace":{"workspace_id":"w4","number":4,"label":"ledger","focused":false,"pane_count":1,"tab_count":1,"active_tab_id":"w4:t1","agent_status":"unknown"},"tab":{"tab_id":"w4:t1","workspace_id":"w4","number":1,"label":"1","focused":false,"pane_count":1,"agent_status":"unknown"},"root_pane":{"pane_id":"w4:p1","terminal_id":"term_0009","workspace_id":"w4","tab_id":"w4:t1","focused":false,"agent_status":"unknown","revision":0}}}"#)
    static let agentStarted = line(#"{"id":"purrdr:agent.start","result":{"type":"agent_started","agent":{"pane_id":"w4:p1"},"argv":["claude"]}}"#)

    static func model(_ connection: FakeHostConnection) -> NewChatModel {
        let folders = NewChatFolders.absolutePathsOnly
        return NewChatModel(launcher: NewChatLauncher(client: HerdrClient(connection: connection), folders: folders), folders: folders)
    }

    @Test("選了資料夾後讀清單:新到舊、預設選「新的聊天」,sessions.list 帶資料夾與 agent 種類")
    func listsSessions() async throws {
        let connection = FakeHostConnection()
        await connection.setHostServiceVersion("0.7.0")
        await connection.expect(.sessionsList, wire: Self.sessionsReply)
        let model = Self.model(connection)
        model.folder = " /Users/demo/ledger "

        await model.refreshSessions()

        guard case .loaded(let sessions) = model.sessions else { Issue.record("sessions: \(model.sessions)"); return }
        #expect(sessions.map(\.id) == ["48b84c34-58a1-465f-94b2-370ed0699957", "0b9e6f1c-2d4a-4c8e-9f00-5a1b2c3d4e5f"])
        #expect(sessions[0].summary == "Add a daily watering reminder to README.md")
        #expect(sessions[1].summary == nil)
        #expect(sessions[0].modified != nil)
        #expect(model.choice == .new)
        let request = try #require(await connection.requests.first)
        #expect(request.contains("/Users/demo/ledger") || request.contains(#"\/Users\/demo\/ledger"#))
        #expect(request.contains(#""agent_kind":"claude""#))
    }

    @Test("換 agent 或資料夾:選擇回到「新的聊天」;Grok 這類不能續接的 agent 不讀清單")
    func resetsChoiceAndSkipsUnsupportedAgents() async {
        let connection = FakeHostConnection()
        await connection.setHostServiceVersion("0.7.0")
        await connection.expect(.sessionsList, wire: Self.sessionsReply)
        let model = Self.model(connection)
        model.folder = "/Users/demo/ledger"
        await model.refreshSessions()
        model.choice = .resume("48b84c34-58a1-465f-94b2-370ed0699957")

        model.agent = .grok
        #expect(model.choice == .new)
        await model.refreshSessions()

        #expect(model.sessions == .idle)
        #expect(await connection.unmetExpectations.isEmpty)
    }

    @Test("SSH 主機(沒有主機服務,#535):照樣讀清單,不提主機服務")
    func sshListsSessions() async throws {
        let connection = FakeHostConnection()
        await connection.expect(.sessionsList, wire: Self.sessionsReply)
        let model = Self.model(connection)
        model.folder = "/Users/demo/ledger"

        await model.refreshSessions()

        guard case .loaded(let sessions) = model.sessions else { Issue.record("sessions: \(model.sessions)"); return }
        #expect(sessions.count == 2)
        #expect(await connection.unmetExpectations.isEmpty)
    }

    @Test("主機服務版本太舊:附依已安裝版本的更新指令,不送 sessions.list")
    func outdatedHostService() async {
        let connection = FakeHostConnection()
        await connection.setHostServiceVersion("0.6.0")
        let model = Self.model(connection)
        model.folder = "/Users/demo/ledger"

        await model.refreshSessions()

        #expect(model.sessions == .updateRequired(HostServiceUpdates.commands(installed: "0.6.0")))
        #expect(await connection.requests.isEmpty)
    }

    @Test("一時連不上主機:說明並可重試,不當成「需要主機服務」也不記住;重試成功就讀清單")
    func unreachableHostCanRetry() async {
        let connection = FakeHostConnection()
        await connection.setHostServiceVersionFailure(HostServiceError.unreachable)
        await connection.expect(.sessionsList, wire: Self.sessionsReply)
        let model = Self.model(connection)
        model.folder = "/Users/demo/ledger"

        await model.refreshSessions()

        guard case .failed = model.sessions else { Issue.record("sessions: \(model.sessions)"); return }

        await connection.setHostServiceVersionFailure(nil)
        await connection.setHostServiceVersion("0.7.0")
        await model.refreshSessions()

        guard case .loaded(let sessions) = model.sessions else { Issue.record("sessions: \(model.sessions)"); return }
        #expect(sessions.count == 2)
    }

    @Test("續接的 session 對話紀錄已不在主機上(transcript_absent):說明這份記錄找不到,不是通用錯誤")
    func absentTranscriptHasOwnMessage() async {
        let connection = FakeHostConnection()
        await connection.setHostServiceVersion("0.7.0")
        await connection.expect(.workspaceCreate, wire: Self.created)
        await connection.stub(.agentStart, failure: TranscriptReadError.absent)
        let model = Self.model(connection)
        model.folder = "/Users/demo/ledger"
        model.choice = .resume("48b84c34-58a1-465f-94b2-370ed0699957")

        let workspace = await model.start()

        #expect(workspace == nil)
        #expect(model.error?.contains("no longer on the host") == true, "error: \(model.error ?? "nil")")
    }

    @Test("續接時第一則訊息可以留空;全新的聊天仍要訊息")
    func resumeAllowsEmptyMessage() async {
        let connection = FakeHostConnection()
        await connection.setHostServiceVersion("0.7.0")
        let model = Self.model(connection)
        model.folder = "/Users/demo/ledger"
        #expect(!model.canStart)

        model.choice = .resume("48b84c34-58a1-465f-94b2-370ed0699957")
        #expect(model.canStart)
        #expect(model.isResuming)

        model.choice = .new
        #expect(!model.canStart)
    }

    @Test("續接開始:agent.start 帶 resume_session、訊息留空就不送 agent.prompt")
    func startsResumedChat() async throws {
        let connection = FakeHostConnection()
        await connection.setHostServiceVersion("0.7.0")
        await connection.expect(.workspaceCreate, wire: Self.created)
        await connection.expect(.agentStart, wire: Self.agentStarted)
        let model = Self.model(connection)
        model.folder = "/Users/demo/ledger"
        model.choice = .resume("48b84c34-58a1-465f-94b2-370ed0699957")

        let workspace = await model.start()

        #expect(workspace == CreatedWorkspace(workspaceID: "w4", rootPaneID: "w4:p1"))
        let requests = await connection.requests
        #expect(requests.count == 2, "只有 workspace.create 與 agent.start")
        let start = try #require(requests.last)
        #expect(start.contains(#""resume_session":"48b84c34-58a1-465f-94b2-370ed0699957""#))
        #expect(model.unsentMessage == nil)
    }

    @Test("全新的聊天開始:agent.start 不帶 resume_session")
    func newChatDoesNotResume() async throws {
        let connection = FakeHostConnection()
        await connection.setHostServiceVersion("0.7.0")
        await connection.expect(.workspaceCreate, wire: Self.created)
        await connection.expect(.agentStart, wire: Self.agentStarted)
        await connection.expect(.agentPrompt, wire: Self.line(#"{"id":"purrdr:agent.prompt","result":{"type":"agent_prompted","delivery":"submitted"}}"#))
        let model = Self.model(connection)
        model.folder = "/Users/demo/ledger"
        model.message = "Fix it"

        _ = await model.start()

        let start = try #require(await connection.requests.dropFirst().first)
        #expect(!start.contains("resume_session"))
    }
}
