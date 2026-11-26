import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 安全送出(#558):直接打 interface,窮舉送出結果;「什麼都沒送出」要與 `sentNothing` 一致。
@MainActor
@Suite("安全送出")
struct SafeSendTests {
    static let paneID = ConversationSendExpectationTests.paneID
    static let session = ConversationSendExpectationTests.session

    static func connection(status: String = "idle") async -> FakeHostConnection {
        let connection = FakeHostConnection()
        await connection.setChecksSendExpectations(true)
        await connection.expect(.snapshot, wire: ConversationSendExpectationTests.snapshot(status))
        return connection
    }

    static func destination(session: String? = session) -> SafeSend.Destination {
        SafeSend.Destination(paneID: paneID, expectedSession: session)
    }

    @Test("主機回對話已變更：什麼都沒送出")
    func hostPaneChanged() async {
        let connection = await Self.connection()
        await connection.stub(.agentPrompt, failure: HostServiceError.paneChanged)
        let result = await SafeSend(client: HerdrClient(connection: connection)).send("hi", to: Self.destination())
        #expect(result == .notSent(.conversationChanged))
        #expect(result.sentNothing)
    }

    @Test("新鮮快照的 session 已換：不送出任何東西")
    func sessionChanged() async {
        let connection = await Self.connection()
        let result = await SafeSend(client: HerdrClient(connection: connection)).send("hi", to: Self.destination(session: "other"))
        #expect(result == .notSent(.conversationChanged))
        #expect(await connection.requests.contains { $0.contains(#""method":"agent.prompt""#) } == false)
    }

    @Test("pane 不在快照裡：什麼都沒送出")
    func agentGone() async {
        let connection = await Self.connection()
        let result = await SafeSend(client: HerdrClient(connection: connection))
            .send("hi", to: SafeSend.Destination(paneID: "w9:p9", expectedSession: nil))
        #expect(result == .notSent(.agentGone))
    }

    @Test("唯讀裝置與 herdr 拒絕：什麼都沒送出")
    func rejections() async {
        let readOnly = await Self.connection()
        await readOnly.stub(.agentPrompt, failure: HostServiceError.readOnlyDevice)
        #expect(await SafeSend(client: HerdrClient(connection: readOnly)).send("hi", to: Self.destination()) == .notSent(.readOnlyDevice))

        let rejected = await Self.connection()
        await rejected.stub(.agentPrompt, failure: HerdrError.herdr(code: "nope", message: "拒絕"))
        let result = await SafeSend(client: HerdrClient(connection: rejected)).send("hi", to: Self.destination())
        #expect(result == .notSent(.rejected("拒絕")))
        #expect(result.sentNothing)
    }

    @Test("窮舉:只有 notSent 算什麼都沒送出;可能已送出的(沒反應、無法確認)不算")
    func sentNothingIsExactlyNotSent() {
        let agent = Agent(paneID: "p", workspaceID: "w", kind: "claude", status: .blocked)
        let notSent: [SafeSend.Result] = [
            .notSent(.agentGone), .notSent(.conversationChanged), .notSent(.needsAnswer(agent)),
            .notSent(.rejected("x")), .notSent(.readOnlyDevice),
        ]
        let maybeSent: [SafeSend.Result] = [
            .delivered, .submittedCommand, .noResponse, .unconfirmed(.connectionLost), .unconfirmed(.mayBeInTerminal),
            .unconfirmed(.codexNoReceipt),
        ]
        #expect(notSent.allSatisfy { $0.sentNothing })
        #expect(maybeSent.allSatisfy { !$0.sentNothing })
    }
}
