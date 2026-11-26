import Foundation
import Observation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    func set() { lock.withLock { raised = true } }
    var value: Bool { lock.withLock { raised } }
}

/// 根畫面不再讀整份合併列表(#581):tab 徽章與視窗指令各自只讀自己要的資料。
@MainActor
@Suite("根畫面的觀察範圍")
struct RootBodyObservationTests {
    /// 第一次讀到 `first` 的 snapshot,第二次讀到 `second`(同一個指令依序消耗)。
    /// `quiet`:第二次讀取時把這些 pane 改成閒置(列表內容變了、但「需要你」的數量不變)。
    static func model(first: [String], second: [String], quiet: [String] = []) async -> HostsModel {
        let host = FakeHost()
        for (blocked, idle) in [(first, [String]()), (second, quiet)] {
            await host.expect(HerdrCommand.bridge(), reply: .recorded("session.snapshot.ndjson") { response in
                for pane in blocked { SnapshotEdit.agent(pane, in: &response) { $0["agent_status"] = "blocked" } }
                for pane in idle { SnapshotEdit.agent(pane, in: &response) { $0["agent_status"] = "idle" } }
            })
        }
        let model = HostsModel(store: MemoryHostStore(), demoChannel: host, makeChannel: { _, _, _ in FakeHost() })
        model.load()
        await model.agentList.load()
        return model
    }

    /// 一次追蹤:回傳 `read` 之後有沒有被通知過。
    static func notified(_ read: () -> Void, after change: () async -> Void) async -> Bool {
        let fired = Flag()
        withObservationTracking { read() } onChange: { fired.set() }
        await change()
        return fired.value
    }

    @Test("徽章數字跟著需要你的數量變")
    func badgeFollowsNeedsYou() async {
        let model = await Self.model(first: ["w1:pA"], second: ["w1:pA", "w1:pB"])
        let badge = NeedsYouBadge(merged: model.agentList)
        badge.start()
        #expect(badge.count == 1)

        await model.agentList.load()
        await Task.yield()
        #expect(badge.count == 2)
    }

    @Test("徽章數字不變時不通知讀它的畫面(列表其他內容變了也一樣)")
    func badgeDoesNotNotifyWhenCountUnchanged() async {
        // 第二次讀取時 pB 從工作中變成閒置:列表變了,需要你的數量(pA)不變。若徽章直接讀整份列表,這個測試就會轉紅。
        let model = await Self.model(first: ["w1:pA"], second: ["w1:pA"], quiet: ["w1:pB"])
        let badge = NeedsYouBadge(merged: model.agentList)
        badge.start()

        let fired = await Self.notified({ _ = badge.count }, after: {
            await model.agentList.load()
            await Task.yield()
        })
        #expect(!fired, "列表重讀但需要你數量沒變,根畫面不該重算")
    }

    @Test("沒有選取聊天時,視窗指令完全不讀列表")
    func windowTargetWithoutSelectionReadsNothing() async {
        let model = await Self.model(first: [], second: ["w1:pA"])
        let merged = model.agentList

        let fired = await Self.notified({ _ = merged.windowTarget(for: nil) }, after: {
            await merged.load()
        })
        #expect(!fired, "沒有選取聊天時,不讀任何主機的資料")
    }

    @Test("windowTarget 與完整 Spaces 投影的「在新視窗開啟」一致")
    func windowTargetMatchesFullProjection() async {
        let model = await Self.model(first: [], second: [])
        let merged = model.agentList
        let tabs = merged.spacesSections.flatMap(\.tabs)
        #expect(!tabs.isEmpty)
        for tab in tabs {
            guard case .pane(let route) = tab.target else { continue }
            let target = merged.windowTarget(for: route)
            let expected = tab.newWindowOpening.flatMap { $0.paneID == route.paneID ? $0 : nil }
            #expect(target.opening == expected, "pane \(route.paneID)")
        }
    }
}
