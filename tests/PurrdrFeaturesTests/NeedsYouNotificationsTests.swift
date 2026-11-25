import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 聊天裡的跨聊天「需要你」通知(#529):轉變才觸發橫幅、目前聊天與靜音不算、收起、離開需要你、不受主機篩選。
@MainActor
@Suite("需要你通知")
struct NeedsYouNotificationsTests {
    typealias Input = NeedsYouNotifications.Input
    static let studio = HostSelection.host(UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!)
    static let lab = HostSelection.host(UUID(uuidString: "00000000-0000-0000-0000-0000000000C2")!)

    static func route(_ pane: String, _ host: HostSelection = studio) -> ChatRoute { ChatRoute(host: host, paneID: pane) }

    /// 一台主機的快照:`blocked` 是需要你的 pane,`muted` 是其中靜音的。
    static func input(
        _ blocked: [String] = [], muted: Set<String> = [], on host: HostSelection = studio, current: Set<ChatRoute> = [],
        others: [NeedsYouNotifications.HostInput] = []
    ) -> Input {
        Input(
            hosts: [.init(host: host, blocked: blocked.map { .init(paneID: $0, isMuted: muted.contains($0)) })] + others,
            current: current)
    }

    final class Clock {
        var date = Date(timeIntervalSince1970: 1_000)
        func advance() -> Date { date.addTimeInterval(1); return date }
    }

    static func model() -> NeedsYouNotifications {
        let clock = Clock()
        return NeedsYouNotifications(now: { clock.advance() })
    }

    @Test("別的狀態變成需要你:橫幅出現,帶那個聊天與總數")
    func transitionTriggersBanner() {
        let model = Self.model()
        model.apply(Self.input())
        #expect(model.banner == nil)

        model.apply(Self.input(["w2:p1"]))

        #expect(model.banner == .init(chat: Self.route("w2:p1"), total: 1))
        #expect(model.others.map(\.route) == [Self.route("w2:p1")])
        #expect(model.latest?.route == Self.route("w2:p1"))
    }

    @Test("第一次拿到快照時已經需要你:進 others,不觸發橫幅,也不是 latest")
    func initiallyBlockedDoesNotTrigger() {
        let model = Self.model()

        model.apply(Self.input(["w2:p1"]))

        #expect(model.banner == nil)
        #expect(model.latest == nil)
        #expect(model.others.map(\.route) == [Self.route("w2:p1")])
    }

    @Test("另一台主機後來才有快照:那台第一份快照已需要你的不觸發")
    func eachHostHasItsOwnBaseline() {
        let model = Self.model()
        model.apply(Self.input())

        model.apply(Self.input(others: [.init(host: Self.lab, blocked: [.init(paneID: "w9:p1", isMuted: false)])]))

        #expect(model.banner == nil)
        #expect(model.others.map(\.route) == [Self.route("w9:p1", Self.lab)])
    }

    @Test("目前開著的聊天變成需要你:不進 others、不觸發;離開後仍不補觸發橫幅")
    func currentChatIsIgnored() {
        let model = Self.model()
        let open = Self.route("w1:p1")
        model.apply(Self.input(current: [open]))

        model.apply(Self.input(["w1:p1"], current: [open]))
        #expect(model.others.isEmpty)
        #expect(model.banner == nil)

        model.apply(Self.input(["w1:p1"], current: []))
        #expect(model.others.map(\.route) == [open])
        #expect(model.banner == nil)
    }

    @Test("靜音的聊天不觸發、不進 others")
    func mutedIsIgnored() {
        let model = Self.model()
        model.apply(Self.input())

        model.apply(Self.input(["w2:p1"], muted: ["w2:p1"]))

        #expect(model.banner == nil)
        #expect(model.others.isEmpty)
    }

    @Test("收起後同一個轉變不再出現;新的轉變才再出現")
    func dismissHidesUntilNewTransition() {
        let model = Self.model()
        model.apply(Self.input())
        model.apply(Self.input(["w2:p1"]))

        model.dismiss()
        #expect(model.banner == nil)
        model.apply(Self.input(["w2:p1"]))
        #expect(model.banner == nil)
        #expect(model.others.count == 1)

        model.apply(Self.input(["w2:p1", "w3:p1"]))
        #expect(model.banner == .init(chat: Self.route("w3:p1"), total: 2))
    }

    @Test("多個:橫幅換成最新的,others 新到舊")
    func newestWins() {
        let model = Self.model()
        model.apply(Self.input())
        model.apply(Self.input(["w2:p1"]))
        model.apply(Self.input(["w2:p1", "w3:p1"]))

        #expect(model.banner == .init(chat: Self.route("w3:p1"), total: 2))
        #expect(model.others.map(\.route) == [Self.route("w3:p1"), Self.route("w2:p1")])
        #expect(model.latest?.route == Self.route("w3:p1"))
    }

    @Test("離開需要你:從所有輸出移除;之後再變成需要你是新的轉變(收起不延續)")
    func leavingRemoves() {
        let model = Self.model()
        model.apply(Self.input())
        model.apply(Self.input(["w2:p1", "w3:p1"]))
        model.dismiss()

        model.apply(Self.input(["w3:p1"]))
        #expect(model.others.map(\.route) == [Self.route("w3:p1")])

        model.apply(Self.input([]))
        #expect(model.others.isEmpty)
        #expect(model.banner == nil)
        #expect(model.latest == nil)

        model.apply(Self.input(["w3:p1"]))
        #expect(model.banner == .init(chat: Self.route("w3:p1"), total: 1))
    }

    @Test("主機暫時沒有快照(斷線):保留紀錄,重連後不被當成新轉變")
    func missingSnapshotKeepsState() {
        let model = Self.model()
        model.apply(Self.input())
        model.apply(Self.input(["w2:p1"]))
        model.dismiss()

        model.apply(Input(hosts: [], current: []))
        model.apply(Self.input(["w2:p1"]))

        #expect(model.banner == nil)
        #expect(model.others.count == 1)
    }

    // MARK: 多視窗(#539)

    @Test("Pane 視窗:別的視窗開著的聊天變成需要你也會觸發;自己視窗的聊天不算")
    func paneWindowIgnoresOnlyItsOwnChat() {
        let model = Self.model()
        let main = Self.route("w1:p1")
        let own = Self.route("w2:p1")
        model.apply(Self.input(current: [main, own]))

        model.apply(Self.input(["w1:p1", "w2:p1"], current: [main, own]))

        #expect(model.banner == nil, "主視窗的規則不變:任何視窗開著的都不算")
        #expect(model.paneBanner(excluding: own) == .init(chat: main, total: 1))
        #expect(model.paneBanner(excluding: main) == .init(chat: own, total: 1))
    }

    @Test("Pane 視窗:多個時總數不含自己的聊天,橫幅是最新的")
    func paneWindowTotalExcludesOwn() {
        let model = Self.model()
        model.apply(Self.input())
        model.apply(Self.input(["w2:p1"]))
        model.apply(Self.input(["w2:p1", "w3:p1"]))

        #expect(model.paneBanner(excluding: Self.route("w9:p1")) == .init(chat: Self.route("w3:p1"), total: 2))
        #expect(model.paneBanner(excluding: Self.route("w3:p1")) == .init(chat: Self.route("w2:p1"), total: 1))
    }

    @Test("收起狀態跨視窗共用:任一視窗收起後另一個也不再顯示同一則")
    func dismissIsSharedAcrossWindows() {
        let model = Self.model()
        let main = Self.route("w1:p1")
        model.apply(Self.input(current: [main]))
        model.apply(Self.input(["w2:p1", "w1:p1"], current: [main]))
        #expect(model.banner?.chat == Self.route("w2:p1"))
        #expect(model.paneBanner(excluding: Self.route("w9:p1")) == .init(chat: main, total: 2), "沒有自己聊天的視窗看到最新的(主視窗開著的)")

        model.dismiss()

        #expect(model.banner == nil)
        #expect(model.paneBanner(excluding: Self.route("w9:p1")) == nil)
        model.apply(Self.input(["w2:p1", "w1:p1"], current: [main]))
        #expect(model.paneBanner(excluding: Self.route("w9:p1")) == nil)
    }

    @Test("Pane 視窗:第一份快照已需要你、靜音的不觸發")
    func paneWindowIgnoresBaselineAndMuted() {
        let model = Self.model()
        model.apply(Self.input(["w2:p1"]))
        model.apply(Self.input(["w2:p1", "w3:p1"], muted: ["w3:p1"]))

        #expect(model.paneBanner(excluding: Self.route("w9:p1")) == nil)
    }

    // MARK: 輸入取自合併列表

    @Test("輸入取自所有主機:不受主機篩選,目前開著的聊天帶進來")
    func inputComesFromAllHosts() async {
        let model = await AgentListHostFilterTests.loadedModel { SnapshotEdit.agent("w1:pB", in: &$0) { $0["agent_status"] = "blocked" } }
        model.currentHost = AgentListHostFilterTests.lab

        let input = model.needsYouInput

        let studio = input.hosts.first { $0.host == AgentListHostFilterTests.studio }
        #expect(studio?.blocked.map(\.paneID) == ["w1:pB"])
        #expect(input.hosts.map(\.host).contains(AgentListHostFilterTests.lab))
        let route = ChatRoute(host: AgentListHostFilterTests.studio, paneID: "w1:pB")
        model.chatAppeared(route)
        #expect(model.needsYouInput.current == [route])
    }

    @Test("run 跟著列表的快照變化更新輸出")
    func runFollowsSnapshots() async throws {
        let merged = await AgentListHostFilterTests.loadedModel { SnapshotEdit.agent("w1:pB", in: &$0) { $0["agent_status"] = "blocked" } }
        let notifications = NeedsYouNotifications()
        let task = Task { await notifications.run(observing: merged) }
        defer { task.cancel() }

        for _ in 0..<50 where notifications.others.isEmpty { try await Task.sleep(for: .milliseconds(20)) }

        #expect(notifications.others.map(\.route.paneID) == ["w1:pB"])
        #expect(notifications.banner == nil, "run 開始前就已經需要你的不觸發")
    }

    @Test("相同輸入再套用一次:不通知觀察者(#589)")
    func identicalInputDoesNotNotify() {
        let model = NeedsYouNotifications()
        let host = Self.studio
        model.apply(.init(hosts: [.init(host: host, blocked: [])], current: []))
        let input = NeedsYouNotifications.Input(hosts: [.init(host: host, blocked: [.init(paneID: "w2:p1", isMuted: false)])], current: [])
        model.apply(input)

        let counter = ChangeCounter()
        func observe() {
            withObservationTracking {
                _ = model.paneBanner(excluding: nil)
                _ = model.others
            } onChange: { counter.count += 1 }
        }
        observe()
        model.apply(input)
        model.apply(input)
        #expect(counter.count == 0, "相同輸入不該遞增 revision 或重設 others")

        model.apply(.init(hosts: [.init(host: host, blocked: [.init(paneID: "w2:p1", isMuted: true)])], current: []))
        #expect(counter.count == 1, "靜音變了才通知")
    }
}

private final class ChangeCounter: @unchecked Sendable { var count = 0 }
