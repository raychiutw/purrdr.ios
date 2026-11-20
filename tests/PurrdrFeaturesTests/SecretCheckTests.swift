import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 機密偵測步驟(#302):偵測到像密鑰的內容時先等使用者決定，決定之前什麼都不送到主機。
@MainActor
@Suite("機密偵測步驟")
struct SecretCheckTests {
    /// 測試用的假 GitHub token(以字串相接，原始碼不出現完整字面值)。
    static let token = ["gh", "p_", "8fK2mQ9xL4vB7nR1tY6uW3zA5cD0eH2jG8sP"].joined()
    static let secretText = "部署失敗\ntoken 是 \(token)"

    static func prompt(_ text: String) -> OutgoingPrompt {
        SendPipelineTests.prompt(text)
    }

    /// 等到步驟開出確認(畫面這時會開 sheet);等不到時讓後面的斷言失敗，不卡住。
    static func waitForReview(_ check: SecretCheck) async {
        for _ in 0..<1_000 where check.review == nil { await Task.yield() }
        #expect(check.review != nil)
    }

    @Test("沒有像密鑰的內容：原樣通過，不開確認")
    func cleanPromptPasses() async {
        let check = SecretCheck()
        let result = await check.process(Self.prompt("整理 CSV 匯出"), clock: SendPipelineTests.clock())
        #expect(result == .proceed(Self.prompt("整理 CSV 匯出")))
        #expect(check.review == nil)
    }

    @Test("偵測到時列出類別與行號；返回編輯：擋下並放回草稿，確認關閉")
    func returnToEditingHalts() async {
        let check = SecretCheck()
        let pending = Task { await check.process(Self.prompt(Self.secretText), clock: SendPipelineTests.clock()) }
        await Self.waitForReview(check)
        #expect(check.review?.findings == [SecretFinding(kind: .gitHubToken, line: 2)])

        check.returnToEditing()

        #expect(await pending.value == .halt(SendHalt(restoresDraft: true)))
        #expect(check.review == nil)
    }

    @Test("仍要送出：原樣交給下一步")
    func sendAnywayProceeds() async {
        let check = SecretCheck()
        let pending = Task { await check.process(Self.prompt(Self.secretText), clock: SendPipelineTests.clock()) }
        await Self.waitForReview(check)

        check.sendAnyway()

        #expect(await pending.value == .proceed(Self.prompt(Self.secretText)))
        #expect(check.review == nil)
    }

    @Test("等待中被取消(離開聊天):當作返回編輯")
    func cancellationReturnsToEditing() async {
        let check = SecretCheck()
        let pending = Task { await check.process(Self.prompt(Self.secretText), clock: SendPipelineTests.clock()) }
        await Self.waitForReview(check)

        pending.cancel()

        #expect(await pending.value == .halt(SendHalt(restoresDraft: true)))
        #expect(check.review == nil)
    }

    // MARK: - 聊天輸入列

    static func opened(check: SecretCheck) async throws -> ConversationSendTests.Setup {
        try await ConversationSendTests.opened { client, transcripts, drafts in
            ConversationModel(
                client: client, transcripts: transcripts, paneID: ConversationSendTests.paneID,
                knownSessionID: ConversationModelTests.sessionID, cache: InMemoryConversationCache(),
                clock: TestClock().clock, drafts: drafts, sendSteps: [check]
            )
        }
    }

    @Test("聊天送出含密鑰的訊息：確認期間主機什麼都沒收到；返回編輯後草稿放回、沒有回音")
    func conversationReturnToEditing() async throws {
        let check = SecretCheck()
        let setup = try await Self.opened(check: check)
        #expect(setup.model.secretCheck === check)
        let before = await setup.host.bridge.executions.count
        setup.model.draft = Self.secretText

        let sending = Task { await setup.model.send() }
        await Self.waitForReview(check)
        #expect(await setup.host.bridge.executions.count == before)
        #expect(setup.model.echoes.isEmpty)

        check.returnToEditing()
        await sending.value

        #expect(await setup.host.bridge.executions.count == before)
        #expect(setup.model.draft == Self.secretText)
        #expect(setup.model.echoes.isEmpty)
    }

    @Test("聊天送出含密鑰的訊息：仍要送出就照常送給主機")
    func conversationSendAnyway() async throws {
        let check = SecretCheck()
        let setup = try await Self.opened(check: check)
        await setup.host.bridge.expect(ConversationSendTests.bridge, reply: ConversationSendTests.snapshot())
        await setup.host.bridge.expect(ConversationSendTests.bridge, reply: ConversationSendTests.delivered)
        setup.model.draft = Self.secretText

        let sending = Task { await setup.model.send() }
        await Self.waitForReview(check)
        check.sendAnyway()
        await sending.value

        let prompts = await ConversationSendTests.promptRequests(setup)
        #expect(prompts.count == 1)
        #expect(setup.model.echoes.map(\.text) == [Self.secretText])
        #expect(setup.model.draft == "")
    }
}
