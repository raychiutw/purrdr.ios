import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 成功送出幾次 prompt 後請求評分(#34)。系統的 `requestReview` 自己決定要不要真的跳出，一年最多三次;
/// app 這邊只決定「什麼時候請求」:同一個版本只請求一次。
@MainActor
@Suite("請求評分")
struct ReviewPromptTests {
    final class Requests {
        var count = 0
    }

    static func prompt(store: any ReviewPromptStore = InMemoryReviewPromptStore(), version: String = "1.0", requests: Requests)
        -> ReviewPrompt {
        ReviewPrompt(store: store, appVersion: version) { requests.count += 1 }
    }

    @Test("成功送出第 3 次才請求;同一個版本之後不再請求")
    func requestsOnceAfterThreeDeliveredPrompts() {
        let requests = Requests()
        let prompt = Self.prompt(requests: requests)

        prompt.promptDelivered()
        prompt.promptDelivered()
        #expect(requests.count == 0)

        prompt.promptDelivered()
        #expect(requests.count == 1)

        for _ in 0..<10 { prompt.promptDelivered() }
        #expect(requests.count == 1)
    }

    @Test("換了版本：再成功送出 3 次才再請求一次")
    func newVersionRequestsAgainAfterThreeMore() {
        let store = InMemoryReviewPromptStore()
        let requests = Requests()
        let first = Self.prompt(store: store, version: "1.0", requests: requests)
        for _ in 0..<3 { first.promptDelivered() }
        #expect(requests.count == 1)

        let second = Self.prompt(store: store, version: "1.1", requests: requests)
        second.promptDelivered()
        second.promptDelivered()
        #expect(requests.count == 1)
        second.promptDelivered()
        #expect(requests.count == 2)
    }

    @Test("次數與已請求的版本存在 UserDefaults:重開 app 後接著算，已請求過的版本不再請求")
    func countsSurviveRelaunch() throws {
        let suite = "ReviewPromptTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let requests = Requests()

        Self.prompt(store: UserDefaultsReviewPromptStore(defaults: defaults), requests: requests).promptDelivered()
        Self.prompt(store: UserDefaultsReviewPromptStore(defaults: defaults), requests: requests).promptDelivered()
        #expect(requests.count == 0)
        Self.prompt(store: UserDefaultsReviewPromptStore(defaults: defaults), requests: requests).promptDelivered()
        #expect(requests.count == 1)

        let relaunched = Self.prompt(store: UserDefaultsReviewPromptStore(defaults: defaults), requests: requests)
        for _ in 0..<3 { relaunched.promptDelivered() }
        #expect(requests.count == 1)
    }

    // MARK: - 對話送出

    static func opened(delivered: Counter) async throws -> ConversationSendTests.Setup {
        let setup = try await ConversationSendTests.opened()
        setup.model.onPromptDelivered = { delivered.count += 1 }
        return setup
    }

    final class Counter {
        var count = 0
    }

    @Test("對話：主機收下 prompt 才算成功送出")
    func deliveredPromptCounts() async throws {
        let delivered = Counter()
        let setup = try await Self.opened(delivered: delivered)
        await setup.host.bridge.expect(ConversationSendTests.bridge, reply: ConversationSendTests.snapshot())
        await setup.host.bridge.expect(ConversationSendTests.bridge, reply: ConversationSendTests.delivered)
        setup.model.draft = "hi"

        await setup.model.send()

        #expect(delivered.count == 1)
    }

    @Test("對話:agent 在等回答(什麼都沒送出)、沒有反應，都不算")
    func undeliveredPromptsDoNotCount() async throws {
        let delivered = Counter()
        let setup = try await Self.opened(delivered: delivered)
        await setup.host.bridge.expect(ConversationSendTests.bridge, reply: ConversationSendTests.snapshot())
        await setup.host.bridge.expect(ConversationSendTests.bridge, reply: PromptReplies.error("agent_blocked", "agent is blocked"))
        setup.model.draft = "繼續"
        await setup.model.send()

        await setup.host.bridge.expect(ConversationSendTests.bridge, reply: ConversationSendTests.snapshot())
        await setup.host.bridge.expect(ConversationSendTests.bridge, reply: .recorded("error.agent-wait-timeout.ndjson"))
        setup.model.draft = "hi"
        await setup.model.send()

        #expect(delivered.count == 0)
    }

    @Test("所有主機、所有聊天共用一份計數：不同聊天各送出一次，第 3 次就請求")
    func chatsShareOneCount() {
        let requests = Requests()
        let hosts = HostsModel(store: MemoryHostStore(), demoChannel: FakeHost(), makeChannel: ChannelFactory().make)
        hosts.reviewPrompt = Self.prompt(requests: requests)
        hosts.load()

        for pane in ["w1:p1", "w2:p1", "w3:p1"] {
            hosts.conversation(ChatRoute(host: .demo, paneID: pane), sessionID: nil).onPromptDelivered?()
        }

        #expect(requests.count == 1)
    }
}
