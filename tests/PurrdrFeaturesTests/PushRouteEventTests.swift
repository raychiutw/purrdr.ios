import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrTestSupport
import Testing

@testable import PurrdrFeatures

/// 點推播通知的路由(#707):依根層 `event`／`status` 分流。
@MainActor
@Suite("推播點擊路由")
struct PushRouteEventTests {
    static let paired = "abc"

    func makeModel() -> (HostsModel, InMemoryPushPairingStore) {
        let store = MemoryHostStore()
        store.hosts = [HostsModelTests.studio]
        let pairings = InMemoryPushPairingStore()
        pairings.setKeyHash(Self.paired, forHost: HostsModelTests.studio.id.uuidString)
        let model = HostsModel(store: store, demoChannel: FakeHost(), makeChannel: ChannelFactory(FakeHost(), FakeHost()).make)
        model.load()
        return (model, pairings)
    }

    @Test("長時間工作完成:有 pane、沒有 event,開聊天")
    func longWorkDoneOpensChat() {
        let (model, pairings) = makeModel()
        let userInfo: [AnyHashable: Any] = ["pairing": Self.paired, "pane": "w1:p1"]
        let route = PushRoute(userInfo: userInfo)!
        #expect(model.open(route, pairings: pairings) == .chat(ChatRoute(host: .host(HostsModelTests.studio.id), paneID: "w1:p1")))
    }

    @Test("預約送出被暫停:根層 status=queue_paused 帶 pane,開聊天")
    func queuePausedOpensChat() {
        let (model, pairings) = makeModel()
        let userInfo: [AnyHashable: Any] = ["pairing": Self.paired, "pane": "w1:p1", "status": "queue_paused"]
        let route = PushRoute(userInfo: userInfo)!
        #expect(model.open(route, pairings: pairings) == .chat(ChatRoute(host: .host(HostsModelTests.studio.id), paneID: "w1:p1")))
    }

    @Test("方案用量快用完:開方案用量頁並帶 Agent;配對不認得也能開")
    func usageAlertOpensPlanUsage() {
        let (model, pairings) = makeModel()
        let userInfo: [AnyHashable: Any] = ["pairing": Self.paired, "event": "usage_alert", "agent": "claude", "threshold": 80]
        let route = PushRoute(userInfo: userInfo)!
        #expect(route.agent == "claude")
        #expect(model.open(route, pairings: pairings) == .planUsage(agent: .claude))
        #expect(model.open(route, pairings: InMemoryPushPairingStore()) == .planUsage(agent: .claude))
    }

    @Test("方案用量快用完:Agent 缺少時開頁但不指定 Agent")
    func usageAlertWithoutAgent() {
        let (model, pairings) = makeModel()
        #expect(model.open(PushRoute(keyHash: Self.paired, paneID: nil, event: "usage_alert"), pairings: pairings) == .planUsage(agent: nil))
    }

    @Test("主機離線與已恢復:開那台主機的主機頁", arguments: ["host_offline", "host_recovered"])
    func hostEventsOpenHostPage(event: String) {
        let (model, pairings) = makeModel()
        let route = PushRoute(keyHash: Self.paired, paneID: nil, event: event)
        #expect(model.open(route, pairings: pairings) == .hostPage(HostsModelTests.studio.id))
    }

    @Test("主機離線:配對已不認得(主機已移除)不開任何畫面")
    func hostOfflineUnknownPairing() {
        let (model, _) = makeModel()
        let route = PushRoute(keyHash: "nope", paneID: nil, event: "host_offline")
        #expect(model.open(route, pairings: InMemoryPushPairingStore()) == nil)
    }

    @Test("每日上限:開帳號頁通知區塊")
    func dailyLimit() {
        let (model, pairings) = makeModel()
        #expect(model.open(PushRoute(keyHash: Self.paired, paneID: nil, event: "daily_limit_reached"), pairings: pairings) == .accountNotifications)
    }

    @Test("主機服務通知(host_service 開頭):開主機編輯頁", arguments: ["host_service_updated", "host_service_update_available"])
    func hostServiceOpensEditor(event: String) {
        let (model, pairings) = makeModel()
        #expect(model.open(PushRoute(keyHash: Self.paired, paneID: nil, event: event), pairings: pairings) == .hostEditor(HostsModelTests.studio.id))
    }

    @Test("未知 event:只開 app,不開任何畫面(有 pane 也一樣)")
    func unknownEvent() {
        let (model, pairings) = makeModel()
        #expect(model.open(PushRoute(keyHash: Self.paired, paneID: nil, event: "something_new"), pairings: pairings) == nil)
        #expect(model.open(PushRoute(keyHash: Self.paired, paneID: "w1:p1", event: "something_new"), pairings: pairings) == nil)
    }

    @Test("測試通知:只開 app")
    func testEvent() {
        let (model, pairings) = makeModel()
        #expect(model.open(PushRoute(keyHash: Self.paired, paneID: nil, event: "test"), pairings: pairings) == nil)
    }
}
