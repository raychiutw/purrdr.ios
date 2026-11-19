import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 載入中與離線(#221):不整頁轉圈;還沒讀到的主機各自顯示連線中，太久顯示仍在連線與再試一次;沒網路直接顯示離線。
@MainActor
@Suite("聊天列表載入中與離線")
struct AgentListLoadingTests {
    static let snapshot = Fixtures.data("session.snapshot.ndjson")
    /// 沒有任何 pane 的主機。
    static let emptySnapshot = Fixtures.modifiedLine("session.snapshot.ndjson") { line in
        var result = line["result"] as? [String: Any] ?? [:]
        var snapshot = result["snapshot"] as? [String: Any] ?? [:]
        for key in ["agents", "panes", "tabs", "layouts"] { snapshot[key] = [Any]() }
        result["snapshot"] = snapshot
        line["result"] = result
    }
    static let studio = HostSelection.host(UUID(uuidString: "00000000-0000-0000-0000-0000000002A1")!)
    static let lab = HostSelection.host(UUID(uuidString: "00000000-0000-0000-0000-0000000002A2")!)
    /// 可以手動推進的時間(測試只在 main actor 上讀寫)。
    final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        func advance(seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    static func source(_ host: HostSelection, name: String, connection: FakeHostConnection, clock: Clock) -> MergedAgentListModel.Source {
        let client = HerdrClient(connection: connection)
        let updates = HostUpdates(client: client, sleep: RecordingSleeper { _ in true }.sleep, now: { clock.now })
        return MergedAgentListModel.Source(
            host: host, name: name, icon: .macMini, list: AgentListModel(updates: updates, host: host),
            actions: WorkspaceActionsModel(client: client, preferences: InMemoryChatPreferencesStore()))
    }

    /// 讀得到快照的主機。
    static func healthy() async -> FakeHostConnection {
        let connection = FakeHostConnection()
        await connection.expect("session.snapshot", reply: snapshot)
        return connection
    }

    /// 讀不到(沒有預期的請求一律失敗)的主機。
    static func failing() -> FakeHostConnection { FakeHostConnection() }

    /// 一直連不上(快照讀取不回應)的主機。
    static func hanging() async -> FakeHostConnection {
        let connection = FakeHostConnection()
        await connection.expect("session.snapshot", reply: snapshot)
        await connection.hold("session.snapshot")
        return connection
    }

    @Test("第一次載入：還在連的主機在狀態列顯示「連線中」,讀到的主機的列照常顯示")
    func connectingHostShowsConnecting() async throws {
        let clock = Clock()
        let lab = await Self.hanging()
        let model = MergedAgentListModel()
        model.update(sources: [
            Self.source(Self.studio, name: "Studio", connection: await Self.healthy(), clock: clock),
            Self.source(Self.lab, name: "Lab", connection: lab, clock: clock),
        ], selected: Self.studio)

        let loading = Task { await model.load() }
        defer { loading.cancel() }
        try await waitUntil { await MainActor.run { model.list(for: Self.studio)?.phase == .loaded } }

        #expect(model.content == .list)
        #expect(model.hostStatuses(at: clock.now) == [HostLoadStatus(host: Self.lab, name: "Lab", icon: .macMini, state: .connecting)])
    }

    @Test("連線超過 10 秒：狀態列改成「仍在連線」(可再試一次)")
    func slowHostShowsStillConnecting() async throws {
        let clock = Clock()
        let model = MergedAgentListModel()
        model.update(sources: [Self.source(Self.lab, name: "Lab", connection: await Self.hanging(), clock: clock)], selected: Self.lab)
        let loading = Task { await model.load() }
        defer { loading.cancel() }

        clock.advance(seconds: 9)
        #expect(model.hostStatuses(at: clock.now).map(\.state) == [.connecting])

        clock.advance(seconds: 1)
        #expect(model.hostStatuses(at: clock.now).map(\.state) == [.stillConnecting])
    }

    @Test("多主機：選取中主機讀不到、其他台讀到但沒有列時，錯誤只在那台主機的狀態行，不佔滿畫面")
    func selectedFailureStaysInItsRowWhenOtherHostLoaded() async throws {
        let clock = Clock()
        let studio = FakeHostConnection()
        await studio.expect("session.snapshot", reply: Self.emptySnapshot)
        let model = MergedAgentListModel()
        model.update(sources: [
            Self.source(Self.lab, name: "Lab", connection: Self.failing(), clock: clock),
            Self.source(Self.studio, name: "Studio", connection: studio, clock: clock),
        ], selected: Self.lab)

        await model.load()

        #expect(model.content == .list)
        #expect(model.failures.map(\.host) == [Self.lab])
    }

    @Test("所有主機都讀不到、也沒有任何列時，選取中主機的錯誤佔滿畫面")
    func allHostsFailingFillsScreen() async throws {
        let clock = Clock()
        let model = MergedAgentListModel()
        model.update(sources: [
            Self.source(Self.lab, name: "Lab", connection: Self.failing(), clock: clock),
            Self.source(Self.studio, name: "Studio", connection: Self.failing(), clock: clock),
        ], selected: Self.lab)

        await model.load()

        guard case .failed = model.content else {
            Issue.record("沒有佔滿畫面的錯誤：\(model.content)")
            return
        }
    }

    @Test("裝置沒有網路、也沒有任何列：直接顯示離線畫面，不等連線逾時")
    func noNetworkWithoutRowsShowsOffline() async throws {
        let clock = Clock()
        let model = MergedAgentListModel()
        model.update(sources: [Self.source(Self.lab, name: "Lab", connection: await Self.hanging(), clock: clock)], selected: Self.lab)
        let loading = Task { await model.load() }
        defer { loading.cancel() }

        model.isNetworkAvailable = false

        #expect(model.content == .offline)
    }

    @Test("裝置沒有網路但已有列：保留列，不顯示各主機的「連線中」")
    func noNetworkKeepsRowsWithoutConnectingStatuses() async throws {
        let clock = Clock()
        let model = MergedAgentListModel()
        model.update(sources: [
            Self.source(Self.studio, name: "Studio", connection: await Self.healthy(), clock: clock),
            Self.source(Self.lab, name: "Lab", connection: await Self.hanging(), clock: clock),
        ], selected: Self.studio)
        let loading = Task { await model.load() }
        defer { loading.cancel() }
        try await waitUntil { await MainActor.run { model.list(for: Self.studio)?.phase == .loaded } }

        model.isNetworkAvailable = false

        #expect(model.content == .list)
        #expect(model.hostStatuses(at: clock.now).isEmpty)
        #expect(model.sections.flatMap(\.rows).count == 3)
    }

    @Test("讀不到的主機有上次的列時按再試一次：列保留，那台主機改成「連線中」,錯誤行收起")
    func retryKeepsCachedRowsAndShowsConnecting() async throws {
        let clock = Clock()
        let lab = await Self.healthy()
        let model = MergedAgentListModel()
        model.update(sources: [Self.source(Self.lab, name: "Lab", connection: lab, clock: clock)], selected: Self.lab)
        await model.load()
        await model.load()
        #expect(model.failures.map(\.host) == [Self.lab])

        clock.advance(seconds: 30)
        model.retry()

        #expect(model.failures.isEmpty)
        #expect(model.hostStatuses(at: clock.now).map(\.state) == [.connecting])
        #expect(model.sections.flatMap(\.rows).count == 3)
        #expect(model.content == .list)
    }

    @Test("仍在連線時按再試一次：丟掉卡住的連線重新開始，狀態回到「連線中」")
    func retryWhileStillConnectingRestartsAttempt() async throws {
        let clock = Clock()
        let lab = await Self.hanging()
        let model = MergedAgentListModel()
        model.update(sources: [Self.source(Self.lab, name: "Lab", connection: lab, clock: clock)], selected: Self.lab)
        let loading = Task { await model.load() }
        defer { loading.cancel() }
        try await waitUntil { await lab.heldCount == 1 }
        clock.advance(seconds: 12)
        #expect(model.hostStatuses(at: clock.now).map(\.state) == [.stillConnecting])

        model.retry()

        try await waitUntil { await lab.disconnectCount == 1 }
        #expect(model.hostStatuses(at: clock.now).map(\.state) == [.connecting])
        #expect(model.failures.isEmpty)
    }
}
