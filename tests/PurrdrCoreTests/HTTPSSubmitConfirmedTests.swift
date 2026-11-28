import Foundation
import PurrdrCore
import PurrdrHTTPS
import PurrdrTestSupport
import Testing

/// 主機服務 0.17.0 的送出確認(#734、purrdr.host#107):`agent.prompt.result` 的 `submit_confirmed`／`enter_sent`。
/// 有 `submit_confirmed` 就採用、app 不再自己等待補 Enter;沒有(舊版主機服務、沒帶 wait、Codex)照舊規則。
@Suite("HTTPS 送出確認")
struct HTTPSSubmitConfirmedTests {
    static let paneID = "w1:p6"
    static let claude = Agent(paneID: paneID, workspaceID: "w1", kind: "claude", status: .idle)

    private static func connection(to service: FakeHostService) -> HTTPSHostConnection {
        HTTPSHostConnection(address: service.address, deviceToken: { "token-ok" }, appVersion: "9.9.9")
    }

    private static func reply(_ settings: FakeHostService.Settings) async throws -> PromptReply {
        let service = try await FakeHostService.start(settings)
        defer { Task { await service.stop() } }
        return try await HerdrClient(connection: connection(to: service)).prompt(target: paneID, text: "hi", wait: .seconds(8))
    }

    // MARK: - 回應欄位

    @Test("submit_confirmed 與 enter_sent 從 agent.prompt.result 帶進 PromptReply")
    func fieldsArePassedThrough() async throws {
        let confirmed = try await Self.reply(.init(promptDelivery: "written_to_pty", promptSubmitConfirmed: true, promptEnterSent: true))
        #expect(confirmed == PromptReply(writtenOnly: true, submitConfirmed: true, enterSent: true))

        let unconfirmed = try await Self.reply(.init(promptDelivery: "written_to_pty", promptSubmitConfirmed: false, promptEnterSent: true))
        #expect(unconfirmed.submitConfirmed == false)
        #expect(unconfirmed.enterSent == true)
    }

    @Test("舊版主機服務沒有這兩個欄位:兩者都是 nil")
    func absentFieldsAreNil() async throws {
        let reply = try await Self.reply(.init(promptDelivery: "written_to_pty"))
        #expect(reply == PromptReply(writtenOnly: true))
        #expect(reply.submitConfirmed == nil)
        #expect(reply.enterSent == nil)
    }

    // MARK: - PromptDelivery

    @Test("submit_confirmed 為 true:直接算送達,不自己等待、不補 Enter")
    func confirmedIsDelivered() async throws {
        let connection = FakeHostConnection()
        await connection.stub(.agentPrompt, PromptReply(writtenOnly: true, submitConfirmed: true, enterSent: true))

        let outcome = await PromptDelivery(client: HerdrClient(connection: connection)).send("hi", to: Self.claude)

        #expect(outcome == .delivered)
        #expect(await connection.typedCalls == ["sendPrompt w1:p6 hi"])
    }

    @Test("submit_confirmed 為 false:照舊規則再等一次(新鮮讀到 idle 才補 Enter),等到了就是送達")
    func unconfirmedFallsBackToOldRule() async throws {
        let connection = FakeHostConnection()
        await connection.stub(.agentPrompt, PromptReply(writtenOnly: true, submitConfirmed: false, enterSent: true))
        await connection.stub(.agentWait, true)

        let outcome = await PromptDelivery(client: HerdrClient(connection: connection)).send("hi", to: Self.claude)

        #expect(outcome == .delivered)
        #expect(await connection.typedCalls == ["sendPrompt w1:p6 hi", "waitForAgent w1:p6"])
    }

    @Test("沒有 submit_confirmed(舊版主機服務):照舊規則,只寫進終端機就等 3.5 秒")
    func absentUsesOldRule() async throws {
        let connection = FakeHostConnection()
        await connection.stub(.agentPrompt, PromptReply(writtenOnly: true))
        await connection.stub(.agentWait, true)

        let outcome = await PromptDelivery(client: HerdrClient(connection: connection)).send("hi", to: Self.claude)

        #expect(outcome == .delivered)
        #expect(await connection.typedCalls == ["sendPrompt w1:p6 hi", "waitForAgent w1:p6"])
    }

    @Test("沒有 submit_confirmed 且 Codex:仍是只能靠對話紀錄確認")
    func absentCodexStaysUnconfirmed() async throws {
        let connection = FakeHostConnection()
        await connection.stub(.agentPrompt, PromptReply(writtenOnly: true))
        let codex = Agent(paneID: Self.paneID, workspaceID: "w1", kind: "codex", status: .idle)

        let outcome = await PromptDelivery(client: HerdrClient(connection: connection)).send("hi", to: codex)

        #expect(outcome == .unconfirmed(.codexNoReceipt))
    }
}
