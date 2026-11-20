import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 送出管線(#299):聊天輸入列的「送出」依序經過可注入的步驟，最後才交給主機。
/// 之後的機密偵測、撤回倒數、離線佇列、帶 `expected_session` 都是插進來的步驟。
@MainActor
@Suite("送出管線")
struct SendPipelineTests {
    nonisolated static let start = Date(timeIntervalSince1970: 1_794_614_400)

    static func prompt(_ text: String = "整理 CSV 匯出") -> OutgoingPrompt {
        OutgoingPrompt(text: text, paneID: "w1:p6", expectedSession: "s-1", createdAt: start)
    }

    static func clock(sleeper: RecordingSleeper = RecordingSleeper()) -> SendPipelineClock {
        SendPipelineClock(now: { start.addingTimeInterval(5) }, sleep: sleeper.sleep)
    }

    @Test("沒有步驟：原樣通過")
    func noStepsPassesThrough() async {
        let pipeline = SendPipeline(steps: [], clock: Self.clock())
        #expect(await pipeline.prepare(Self.prompt()) == .proceed(Self.prompt()))
    }

    @Test("步驟依序執行，每一步拿到前一步改過的內容")
    func stepsRunInOrder() async {
        var seen: [String] = []
        let pipeline = SendPipeline(steps: [
            SendStepClosure { prompt, _ in
                seen.append("a:" + prompt.text)
                var next = prompt
                next.text += "!"
                return .proceed(next)
            },
            SendStepClosure { prompt, _ in
                seen.append("b:" + prompt.text)
                return .proceed(prompt)
            },
        ], clock: Self.clock())

        let result = await pipeline.prepare(Self.prompt("hi"))

        #expect(seen == ["a:hi", "b:hi!"])
        #expect(result == .proceed(OutgoingPrompt(text: "hi!", paneID: "w1:p6", expectedSession: "s-1", createdAt: Self.start)))
    }

    @Test("步驟擋下：後面的步驟不執行，結果帶擋下的原因")
    func haltStopsLaterSteps() async {
        var laterRan = false
        let pipeline = SendPipeline(steps: [
            SendStepClosure { _, _ in .halt(SendHalt(restoresDraft: true)) },
            SendStepClosure { prompt, _ in
                laterRan = true
                return .proceed(prompt)
            },
        ], clock: Self.clock())

        #expect(await pipeline.prepare(Self.prompt()) == .halt(SendHalt(restoresDraft: true)))
        #expect(!laterRan)
    }

    @Test("步驟拿到注入的時鐘(現在時間與等待)")
    func stepsUseInjectedClock() async throws {
        let sleeper = RecordingSleeper { _ in true }
        var now: Date?
        let pipeline = SendPipeline(steps: [
            SendStepClosure { prompt, clock in
                now = clock.now()
                try? await clock.sleep(.seconds(3))
                return .proceed(prompt)
            },
        ], clock: Self.clock(sleeper: sleeper))

        _ = await pipeline.prepare(Self.prompt())

        #expect(now == Self.start.addingTimeInterval(5))
        #expect(await sleeper.requested == [.seconds(3)])
    }

    // MARK: - 聊天輸入列走管線

    @Test("聊天送出經過管線：步驟拿到 pane、預期的 session 與文字，改過的文字才送給主機")
    func conversationSendGoesThroughPipeline() async throws {
        var seen: OutgoingPrompt?
        let setup = try await ConversationSendTests.opened { client, transcripts, drafts in
            ConversationModel(
                client: client, transcripts: transcripts, paneID: ConversationSendTests.paneID,
                knownSessionID: ConversationModelTests.sessionID, cache: InMemoryConversationCache(),
                clock: TestClock().clock, drafts: drafts,
                sendSteps: [SendStepClosure { prompt, _ in
                    seen = prompt
                    var next = prompt
                    next.text = "改過的"
                    return .proceed(next)
                }]
            )
        }
        await setup.host.bridge.expect(ConversationSendTests.bridge, reply: ConversationSendTests.snapshot())
        await setup.host.bridge.expect(ConversationSendTests.bridge, reply: ConversationSendTests.delivered)
        setup.model.draft = "  原本的  "

        await setup.model.send()

        #expect(seen?.text == "原本的")
        #expect(seen?.paneID == ConversationSendTests.paneID)
        #expect(seen?.expectedSession == ConversationModelTests.sessionID)
        let prompts = await ConversationSendTests.promptRequests(setup)
        #expect(prompts.count == 1)
        #expect(prompts.first?.contains(#""text":"改過的""#) == true)
        #expect(setup.model.echoes.map(\.text) == ["改過的"])
    }

    @Test("管線擋下且要放回草稿：什麼都沒送、沒有回音、草稿放回")
    func haltRestoresDraft() async throws {
        let setup = try await ConversationSendTests.opened { client, transcripts, drafts in
            ConversationModel(
                client: client, transcripts: transcripts, paneID: ConversationSendTests.paneID,
                knownSessionID: ConversationModelTests.sessionID, cache: InMemoryConversationCache(),
                clock: TestClock().clock, drafts: drafts,
                sendSteps: [SendStepClosure { _, _ in .halt(SendHalt(restoresDraft: true)) }]
            )
        }
        setup.model.draft = "先別送"

        await setup.model.send()

        #expect(await ConversationSendTests.promptRequests(setup).isEmpty)
        #expect(setup.model.echoes.isEmpty)
        #expect(setup.model.draft == "先別送")
        #expect(!setup.model.isSending)
    }

    @Test("管線擋下且由步驟接手(例如排進佇列):草稿不放回")
    func haltWithoutRestoreKeepsDraftEmpty() async throws {
        let setup = try await ConversationSendTests.opened { client, transcripts, drafts in
            ConversationModel(
                client: client, transcripts: transcripts, paneID: ConversationSendTests.paneID,
                knownSessionID: ConversationModelTests.sessionID, cache: InMemoryConversationCache(),
                clock: TestClock().clock, drafts: drafts,
                sendSteps: [SendStepClosure { _, _ in .halt(SendHalt(restoresDraft: false)) }]
            )
        }
        setup.model.draft = "排隊"

        await setup.model.send()

        #expect(await ConversationSendTests.promptRequests(setup).isEmpty)
        #expect(setup.model.echoes.isEmpty)
        #expect(setup.model.draft == "")
    }
}
