import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrSSH
import PurrdrTestSupport
import Testing

/// 送出前比對(#304):聊天送出與回答把 app 看到的 session(回答另帶畫面指紋)交給主機比對;
/// 主機回 `pane_changed`(對話已變更)時什麼都沒送出，草稿保留並提示。假連線扮演 0.7.0 起的主機服務。
@MainActor
@Suite("對話：送出前比對")
struct ConversationSendExpectationTests {
    static let paneID = "w1:p6"
    /// 錄製的 snapshot 裡 w1:p6 的 session。
    static let session = "00000000-0000-0000-0000-000000000001"

    static func snapshot(_ status: String) -> Data {
        Fixtures.modifiedLine("session.snapshot.ndjson") { SnapshotEdit.agent(paneID, in: &$0) { $0["agent_status"] = status } }
    }

    static func paneRead(text: String) -> Data {
        Fixtures.modifiedLine("pane.read.visible.ndjson") { response in
            guard var result = response["result"] as? [String: Any], var read = result["read"] as? [String: Any] else { return }
            read["text"] = text
            result["read"] = read
            response["result"] = result
        }
    }

    static func opened(status: String = "idle") async -> (FakeHostConnection, ConversationModel) {
        let connection = FakeHostConnection()
        await connection.setChecksSendExpectations(true)
        let model = ConversationModel(
            client: HerdrClient(connection: connection), transcripts: TranscriptReader(connection: connection), paneID: paneID,
            knownSessionID: session, cache: InMemoryConversationCache(), clock: ConversationClock(now: { Date(timeIntervalSince1970: 1_794_614_400) }))
        await connection.expect(.snapshot, wire: snapshot(status))
        return (connection, model)
    }

    static func params(of method: String, in connection: FakeHostConnection) async throws -> [String: Any] {
        let line = try #require(await connection.requests.last { $0.contains(#""method":"\#(method)""#) })
        let request = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        return try #require(request["params"] as? [String: Any])
    }

    @Test("送出帶 app 看到的 session;主機回對話已變更：沒有回音、草稿放回、提示對話已變更")
    func paneChangedRestoresDraft() async throws {
        let (connection, model) = await Self.opened()
        await model.poll()
        await connection.expect(.snapshot, wire: Self.snapshot("idle"))
        await connection.stub(.agentPrompt, failure: HostServiceError.paneChanged)
        model.draft = "給原本的對話"

        await model.send()

        let sent = try await Self.params(of: "agent.prompt", in: connection)
        #expect(sent["expected_session"] as? String == Self.session)
        #expect(sent["expected_screen"] == nil)
        #expect(model.draft == "給原本的對話")
        #expect(model.notice == .superseded)
        #expect(model.echoes.isEmpty)
    }

    @Test("帶附件、主機回對話已變更：什麼都沒送出，草稿、附件與手機上的檔案副本都保留(#558)")
    func paneChangedKeepsAttachments() async throws {
        let connection = FakeHostConnection()
        await connection.setChecksSendExpectations(true)
        let store = FileAttachmentStore(directory: FileManager.default.temporaryDirectory.appending(path: "purrdr-attachments-\(UUID().uuidString)"))
        let fileName = HostUploadName("mh1a2b3c-k9x2m4p7-server.log")!
        let model = ConversationModel(
            client: HerdrClient(connection: connection), transcripts: TranscriptReader(connection: connection), paneID: Self.paneID,
            knownSessionID: Self.session, cache: InMemoryConversationCache(),
            clock: ConversationClock(now: { Date(timeIntervalSince1970: 1_794_614_400) }),
            images: ComposerAttachments.Dependencies(uploader: FakeHostUploader(), store: store, makeFileName: { _ in fileName }))
        await connection.expect(.snapshot, wire: Self.snapshot("idle"))
        await model.poll()
        await model.addFile(named: "server.log", size: 5) { Data("hello".utf8) }
        let id = try #require(model.attachments.first).id
        await connection.expect(.snapshot, wire: Self.snapshot("idle"))
        await connection.stub(.agentPrompt, failure: HostServiceError.paneChanged)
        model.draft = "給原本的對話"

        await model.send()

        #expect(model.notice == .superseded)
        #expect(model.draft == "給原本的對話")
        #expect(model.attachments.count == 1)
        #expect(store.url(of: id) != nil)
    }

    @Test("回答選擇題只帶 session,不帶畫面指紋(主機讀畫面的行數與 app 不同，指紋必不符)")
    func answerCarriesSessionOnly() async throws {
        let (connection, model) = await Self.opened(status: "blocked")
        let screen = PaneScreens.text("claude-bash")
        await connection.expect(.paneRead, wire: Self.paneRead(text: screen))
        await model.poll()
        let option = try #require(model.prompt?.options.first)
        await connection.expect(.sendKeys, wire: Data(#"{"id":"purrdr:pane.send_keys","result":{"type":"ok"}}"#.utf8))

        await model.answer(.option(option))

        let sent = try await Self.params(of: "pane.send_keys", in: connection)
        #expect(sent["expected_session"] as? String == Self.session)
        #expect(sent["expected_screen"] == nil)
    }

    @Test("回答時題目已變：解鎖選項、提示題目已變更，並立刻重讀畫面")
    func answerToChangedQuestion() async throws {
        let (connection, model) = await Self.opened(status: "blocked")
        await connection.expect(.paneRead, wire: Self.paneRead(text: PaneScreens.text("claude-bash")))
        await model.poll()
        let option = try #require(model.prompt?.options.first)
        await connection.stub(.sendKeys, failure: HostServiceError.paneChanged)
        await connection.expect(.snapshot, wire: Self.snapshot("blocked"))
        await connection.expect(.paneRead, wire: Self.paneRead(text: PaneScreens.text("claude-bash")))

        await model.answer(.option(option))

        #expect(model.answerNotice == .questionChanged)
        #expect(!model.isAnswering(option))
        #expect(model.canAnswer(.option(option)))
        #expect(await connection.unmetExpectations.isEmpty)
    }

    @Test("切換權限模式的 Shift+Tab 帶 session;主機回對話已變更就不再按、說明切換失敗")
    func permissionModeKeysCarrySession() async throws {
        let (connection, model) = await Self.opened()
        await model.poll()
        let ok = Data(#"{"id":"purrdr:pane.send_keys","result":{"type":"ok"}}"#.utf8)
        await connection.expect(.paneRead, wire: Self.paneRead(text: "> \n  ? for shortcuts\n"))
        await connection.stub(.sendKeys, failure: HostServiceError.paneChanged)

        await model.setPermissionMode(.plan)

        let sent = try await Self.params(of: "pane.send_keys", in: connection)
        #expect(sent["expected_session"] as? String == Self.session)
        #expect(model.permissionModeFailure == .paneChanged(target: .plan))
        _ = ok
    }
}
