import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrHTTPS
import Testing

/// HTTPS 主機的 Agent 列表即時更新(#58):`AgentListModel` 經真正的 WebSocket 連假的主機服務。
@MainActor
@Suite("HTTPS Agent 列表即時更新")
struct HTTPSAgentListLiveTests {
    private static func model(for service: FakeHostService) -> AgentListModel {
        AgentListModel(
            client: HerdrClient(connection: HTTPSLiveUpdatesTests.connection(to: service)),
            sleep: { _ in try await Task.sleep(for: .milliseconds(10)) })
    }

    private static func status(of paneID: String, in model: AgentListModel) -> AgentStatus? {
        model.snapshot?.agents.first(where: { $0.paneID == paneID })?.status
    }

    @Test("斷線期間 Agent 變成「需要你」:重連後列表對帳補上")
    func reconnectReconcilesMissedChanges() async throws {
        let service = try await FakeHostService.start()
        defer { Task { await service.stop() } }
        let model = Self.model(for: service)
        let live = Task { await model.run() }
        defer { live.cancel() }
        // 等訂閱開始時的對帳讀完：還在讀時改了主機的狀態，第一條連線就會讀到 blocked,看不出重連有沒有對帳。
        try await waitUntil { await MainActor.run { model.updates.isSubscribed } }
        #expect(Self.status(of: "w1:p6", in: model) == .idle)

        service.update { $0.agentsReply = .statuses(["w1:p6": "blocked"]) }
        await service.dropConnections()

        try await waitUntil { await Self.status(of: "w1:p6", in: model) == .blocked }
        try await waitUntil { service.openStreams.count == 1 }
        #expect(model.phase == .loaded)
        #expect(service.log.connections == 2)
    }

    @Test("主機服務推送狀態改變：列表重讀後立即更新")
    func pushedEventRefreshesList() async throws {
        let service = try await FakeHostService.start()
        defer { Task { await service.stop() } }
        let model = Self.model(for: service)
        let live = Task { await model.run() }
        defer { live.cancel() }
        try await waitUntil { service.openStreams.count == 1 }

        service.update { $0.agentsReply = .statuses(["w1:p6": "blocked"]) }
        service.pushEvent("pane_agent_status_changed", paneID: "w1:p6")

        try await waitUntil { await Self.status(of: "w1:p6", in: model) == .blocked }
        #expect(service.log.connections == 1)
    }

    @Test("herdr 沒有事件訂閱能力：列表照常顯示，不標成失敗(只停用即時更新)")
    func listStaysLoadedWithoutEvents() async throws {
        let service = try await FakeHostService.start(.init(subscribeReply: .error(code: "herdr_capability_missing")))
        defer { Task { await service.stop() } }
        let model = Self.model(for: service)
        let live = Task { await model.run() }
        defer { live.cancel() }

        try await waitUntil { service.log.messages.filter { $0.contains(#""type":"events.subscribe""#) }.count >= 2 }

        #expect(model.phase == .loaded)
        #expect(model.snapshot?.agents.count == 2)
    }
}
