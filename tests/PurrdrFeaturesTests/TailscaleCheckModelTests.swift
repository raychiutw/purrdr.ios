import Foundation
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Synchronization
import Testing

@MainActor
@Suite("Tailscale SSH check mode 提示")
struct TailscaleCheckModelTests {
    static let url = URL(string: "https://login.tailscale.com/a/1a2b3c4d5e6f7")!

    @Test("主機通道回報要驗證：顯示驗證網址;驗證完(回報結束)就收起")
    func showsAndDismissesPrompt() async throws {
        let model = TailscaleCheckModel()

        model.observer(TailscaleCheckPrompt(url: Self.url) {})
        try await until { model.url != nil }
        #expect(model.url == Self.url)

        model.observer(nil)
        try await until { model.url == nil }
    }

    @Test("取消等待：立即收起提示，並請主機通道取消這次連線")
    func cancelStopsWaiting() async throws {
        let model = TailscaleCheckModel()
        let cancelled = Mutex(false)
        model.observer(TailscaleCheckPrompt(url: Self.url) { cancelled.withLock { $0 = true } })
        try await until { model.url != nil }

        await model.cancel()

        #expect(model.url == nil)
        #expect(cancelled.withLock { $0 })
    }

    @Test("取消後連線失敗：Agent 列表說明是取消了 Tailscale 驗證")
    func cancelledCheckExplainedInAgentList() async {
        let store = MemoryHostStore()
        store.hosts = [HostsModelTests.studio]
        let host = FakeHost()
        await host.failConnection(with: SSHConnectionError.tailscaleCheckCancelled)
        let model = HostsModel(store: store, demoChannel: FakeHost(), makeChannel: ChannelFactory(host).make)

        model.load()
        await model.agentList.load()

        #expect(model.agentList.phase == .failed("Tailscale sign-in was canceled. Try again when you’re ready to sign in."))
    }

    @Test("一直沒完成驗證：Agent 列表說明 Tailscale 驗證逾時")
    func timedOutCheckExplainedInAgentList() async {
        let store = MemoryHostStore()
        store.hosts = [HostsModelTests.studio]
        let host = FakeHost()
        await host.failConnection(with: SSHConnectionError.tailscaleCheckTimedOut)
        let model = HostsModel(store: store, demoChannel: FakeHost(), makeChannel: ChannelFactory(host).make)

        model.load()
        await model.agentList.load()

        #expect(model.agentList.phase == .failed("The Tailscale sign-in wasn’t finished in time. Try again."))
    }

    /// 輪詢到條件成立(提示經 main actor 非同步送達;上限 `asyncWaitLimit`)。
    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + asyncWaitLimit
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("等不到條件成立")
    }
}
