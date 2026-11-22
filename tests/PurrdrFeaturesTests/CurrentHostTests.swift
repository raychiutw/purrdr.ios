import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrHTTPS
import PurrdrTestSupport
import Testing

/// 全 app 共用的目前主機(#334):存在本機、刪除主機時回到所有主機、方案用量跟著它並回寫。
@MainActor
@Suite("目前主機")
struct CurrentHostTests {
    static let ssh = HostConfiguration(name: "Studio", endpoint: SSHEndpoint(host: "studio-mac", username: "ray"))
    static let https = HostConfiguration(name: "Box", hostService: HostServiceAddress("box.tail1234.ts.net")!)

    static func model(
        currentHost: any CurrentHostStore = InMemoryCurrentHostStore(), planUsage: any PlanUsageSelectionStore = InMemoryPlanUsageSelectionStore()
    ) -> HostsModel {
        let store = MemoryHostStore()
        store.hosts = [ssh, https]
        let model = HostsModel(
            store: store, demoChannel: FakeHost(), currentHost: currentHost, planUsageSelection: planUsage,
            hostService: HostServiceConnections().access(tokens: InMemoryDeviceTokenStore(tokens: [https.id: "token-saved"])),
            makeChannel: ChannelFactory().make)
        model.load()
        return model
    }

    @Test("預設是所有主機")
    func defaultsToAllHosts() {
        #expect(Self.model().agentList.currentHost == nil)
    }

    @Test("改了存起來，重開 app 仍是同一台")
    func persistsAcrossLaunches() {
        let store = InMemoryCurrentHostStore()
        let first = Self.model(currentHost: store)
        first.agentList.currentHost = .host(Self.https.id)

        #expect(store.load() == .host(Self.https.id))
        #expect(Self.model(currentHost: store).agentList.currentHost == .host(Self.https.id))
        withExtendedLifetime(first) {}
    }

    @Test("選回所有主機也存起來")
    func allHostsIsPersisted() {
        let store = InMemoryCurrentHostStore()
        let model = Self.model(currentHost: store)
        model.agentList.currentHost = .host(Self.https.id)
        model.agentList.currentHost = nil

        #expect(store.load() == nil)
        let reopened = Self.model(currentHost: store)
        #expect(reopened.agentList.currentHost == nil)
        withExtendedLifetime(model) {}
    }

    @Test("存的那台主機已不存在：回到所有主機")
    func missingStoredHostFallsBackToAllHosts() {
        let store = InMemoryCurrentHostStore(.host(UUID()))

        let reopened = Self.model(currentHost: store)
        #expect(reopened.agentList.currentHost == nil)
    }

    @Test("刪除目前主機：回到所有主機，存的值也清掉")
    func deletingCurrentHostResetsToAllHosts() async throws {
        let store = InMemoryCurrentHostStore()
        let model = Self.model(currentHost: store)
        model.agentList.currentHost = .host(Self.https.id)

        try await model.delete(Self.https.id)

        #expect(model.agentList.currentHost == nil)
        #expect(store.load() == nil)
    }

    @Test("刪除別台主機不影響目前主機")
    func deletingOtherHostKeepsCurrentHost() async throws {
        let model = Self.model()
        model.agentList.currentHost = .host(Self.ssh.id)

        try await model.delete(Self.https.id)

        #expect(model.agentList.currentHost == .host(Self.ssh.id))
    }

    @Test("方案用量開啟時預設目前主機，優先於上次在方案用量選的")
    func planUsageStartsOnCurrentHost() {
        let planStore = InMemoryPlanUsageSelectionStore(PlanUsageSelection(host: .host(Self.ssh.id), agent: .claudeCode))
        let model = Self.model(planUsage: planStore)
        model.agentList.currentHost = .host(Self.https.id)

        #expect(model.planUsage().host == .host(Self.https.id))
    }

    @Test("目前主機是所有主機：方案用量用上次選的")
    func planUsageUsesRememberedHostWhenAllHosts() {
        let planStore = InMemoryPlanUsageSelectionStore(PlanUsageSelection(host: .host(Self.ssh.id), agent: .claudeCode))
        let model = Self.model(planUsage: planStore)

        #expect(model.planUsage().host == .host(Self.ssh.id))
    }

    @Test("方案用量與網路流量改主機只改自己的選取,不動聊天列表的目前主機與選取中主機(切換規則)")
    func usageHostChangesDoNotTouchCurrentHost() {
        let model = Self.model()
        model.select(.host(Self.https.id))
        model.agentList.currentHost = .host(Self.https.id)

        let plan = model.planUsage()
        plan.select(host: .host(Self.ssh.id))
        #expect(plan.host == .host(Self.ssh.id))
        #expect(model.agentList.currentHost == .host(Self.https.id))
        #expect(model.selection == .host(Self.https.id))

        let traffic = model.dataUsage()
        traffic.selectHost(.host(Self.ssh.id))
        #expect(traffic.host == .host(Self.ssh.id))
        #expect(model.agentList.currentHost == .host(Self.https.id))
        #expect(model.selection == .host(Self.https.id))
    }

    @Test("新增聊天預設目前主機，所有主機時用選取中主機")
    func newChatStartsOnCurrentHost() {
        let model = Self.model()
        model.select(.host(Self.ssh.id))
        #expect(model.newChatHostPicker().selection == .host(Self.ssh.id))

        model.agentList.currentHost = .host(Self.https.id)
        #expect(model.newChatHostPicker().selection == .host(Self.https.id))
    }
}
