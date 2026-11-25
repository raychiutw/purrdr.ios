import Foundation
import PurrdrAgentFeatures
import PurrdrCore
@testable import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 可調整的時鐘(釘選時間、開啟時間)。
final class MarkerClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

/// 未讀標示、「已釘選」群組、各組數量、需處理的 workspace 數與滑動提示(#41;#37 故事 15–20,行為規格 F2.2、F2.5、F2.6、F2.8、F2.7)。
@MainActor
@Suite("未讀與已釘選")
struct UnreadPinnedTests {
    static let bridge = HerdrCommand.bridge()
    static let studio = HostSelection.host(UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!)
    static let lab = HostSelection.host(UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!)
    /// 錄製 snapshot 裡 `w1:p6`(idle)的 session。
    static let sessionP6 = "00000000-0000-0000-0000-000000000001"
    static let sessionA = "00000000-0000-0000-0000-000000000002"
    static let sessionB = "00000000-0000-0000-0000-000000000003"
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// 一台主機：依序回 `snapshots`(每次 `load()` 一份),偏好在 `preferences`。
    struct Host {
        let source: MergedAgentListModel.Source
        let fake: FakeHost
    }

    static func host(
        _ host: HostSelection, name: String = "Studio", clock: MarkerClock, preferences: any ChatPreferencesStore = InMemoryChatPreferencesStore(),
        snapshots: [((inout [String: Any]) -> Void)?] = [nil]
    ) async -> Host {
        let fake = FakeHost()
        for modify in snapshots {
            await fake.expect(bridge, reply: modify.map { .recorded("session.snapshot.ndjson", modify: $0) } ?? .recorded("session.snapshot.ndjson"))
        }
        let client = HerdrClient(channel: fake)
        let list = AgentListModel(client: client, host: host)
        let actions = WorkspaceActionsModel(client: client, preferences: preferences, now: { clock.now })
        return Host(source: MergedAgentListModel.Source(host: host, name: name, icon: .default, list: list, actions: actions), fake: fake)
    }

    static func merged(_ hosts: [Host], selected: HostSelection = studio) -> MergedAgentListModel {
        let model = MergedAgentListModel()
        model.update(sources: hosts.map(\.source), selected: selected)
        return model
    }

    static func row(_ paneID: String, host: HostSelection = studio, in model: MergedAgentListModel) -> AgentRow? {
        model.sections.flatMap(\.rows).first { $0.paneID == paneID && $0.host == host }
    }

    static func preview(_ date: Date?, fromUser: Bool = false) -> MessagePreview {
        MessagePreview(text: "好了", date: date, isFromUser: fromUser)
    }

    // MARK: - 未讀

    @Test("有新回覆、從未開啟的聊天是未讀(實心圓);開啟後已讀(空心圓);之後再有新回覆又變未讀")
    func unreadUntilOpened() async {
        let clock = MarkerClock(Self.t0)
        let studio = await Self.host(Self.studio, clock: clock)
        let model = Self.merged([studio])
        await model.load()
        studio.source.list.previews = ["w1:p6": Self.preview(Self.t0.addingTimeInterval(-60))]

        #expect(Self.row("w1:p6", in: model)?.isUnread == true)
        #expect(Self.row("w1:p6", in: model)?.status == .done, "未讀應顯示為實心圓(done)")

        model.chatAppeared(ChatRoute(host: Self.studio, paneID: "w1:p6"))
        clock.now = Self.t0.addingTimeInterval(30)
        model.chatDisappeared(ChatRoute(host: Self.studio, paneID: "w1:p6"))

        #expect(Self.row("w1:p6", in: model)?.isUnread == false)
        #expect(Self.row("w1:p6", in: model)?.status == .idle, "已讀應顯示為空心圓(idle)")

        studio.source.list.previews = ["w1:p6": Self.preview(Self.t0.addingTimeInterval(120))]
        #expect(Self.row("w1:p6", in: model)?.isUnread == true)
    }

    @Test("主機時鐘比手機快(回覆時間在手機的「現在」之後):開過就算讀過，不會永遠清不掉")
    func openingClearsUnreadDespiteHostClockAhead() async {
        let clock = MarkerClock(Self.t0)
        let studio = await Self.host(Self.studio, clock: clock)
        let model = Self.merged([studio])
        await model.load()
        studio.source.list.previews = ["w1:p6": Self.preview(Self.t0.addingTimeInterval(3600))]

        model.chatAppeared(ChatRoute(host: Self.studio, paneID: "w1:p6"))
        model.chatDisappeared(ChatRoute(host: Self.studio, paneID: "w1:p6"))

        #expect(Self.row("w1:p6", in: model)?.isUnread == false)
    }

    @Test("herdr 回報 done 但已讀過 → 空心圓;回報 idle 但有未讀回覆 → 實心圓")
    func unreadOverridesHerdrStatus() async {
        let clock = MarkerClock(Self.t0)
        let preferences = InMemoryChatPreferencesStore(ChatPreferences(opened: [Self.sessionP6: Self.t0]))
        let studio = await Self.host(Self.studio, clock: clock, preferences: preferences, snapshots: [{
            SnapshotEdit.agent("w1:p6", in: &$0) { $0["agent_status"] = "done" }
        }])
        let model = Self.merged([studio])
        await model.load()
        studio.source.list.previews = ["w1:p6": Self.preview(Self.t0.addingTimeInterval(-10))]

        #expect(Self.row("w1:p6", in: model)?.status == .idle)
    }

    @Test("自己送出的訊息、沒有時間的預覽、沒有預覽都不算未讀")
    func ownMessagesAreNotUnread() async {
        let clock = MarkerClock(Self.t0)
        let studio = await Self.host(Self.studio, clock: clock, snapshots: [{
            SnapshotEdit.agent("w1:pA", in: &$0) { $0["agent_status"] = "idle" }
            SnapshotEdit.agent("w1:pB", in: &$0) { $0["agent_status"] = "idle" }
        }])
        let model = Self.merged([studio])
        await model.load()
        studio.source.list.previews = [
            "w1:p6": Self.preview(Self.t0, fromUser: true),
            "w1:pA": Self.preview(nil),
        ]

        #expect(Self.row("w1:p6", in: model)?.isUnread == false, "自己的訊息不算未讀")
        #expect(Self.row("w1:pA", in: model)?.isUnread == false, "沒有時間的預覽不算未讀")
        #expect(Self.row("w1:pB", in: model)?.isUnread == false, "沒有預覽不算未讀")
        #expect(Self.row("w1:p6", in: model)?.status == .idle)
    }

    @Test("herdr 回收 pane 給新 session:讀過的舊 session 不算數，新 session 重新算未讀")
    func newSessionInSamePaneIsUnreadAgain() async {
        let clock = MarkerClock(Self.t0)
        let studio = await Self.host(Self.studio, clock: clock, snapshots: [nil, {
            SnapshotEdit.agent("w1:p6", in: &$0) {
                $0["agent_session"] = ["source": "herdr:claude", "agent": "claude", "kind": "id", "value": "00000000-0000-0000-0000-0000000000cc"]
            }
        }])
        let model = Self.merged([studio])
        await model.load()
        let route = ChatRoute(host: Self.studio, paneID: "w1:p6")
        model.chatAppeared(route)
        model.chatDisappeared(route)
        clock.now = Self.t0.addingTimeInterval(600)

        await model.load()
        // 新 session 的回覆時間早於上次開啟這個 pane 的時間：仍算未讀(讀的是別的 session)。
        studio.source.list.previews = ["w1:p6": Self.preview(Self.t0.addingTimeInterval(-60))]

        #expect(Self.row("w1:p6", in: model)?.isUnread == true)
    }

    @Test("目前開著的聊天(iPad 開在旁邊)不算未讀，開著時來的新回覆也不算")
    func visibleChatIsNeverUnread() async {
        let clock = MarkerClock(Self.t0)
        let studio = await Self.host(Self.studio, clock: clock)
        let model = Self.merged([studio])
        await model.load()
        model.chatAppeared(ChatRoute(host: Self.studio, paneID: "w1:p6"))

        studio.source.list.previews = ["w1:p6": Self.preview(Self.t0.addingTimeInterval(300))]

        #expect(Self.row("w1:p6", in: model)?.isUnread == false)
    }

    @Test("iPad 多視窗：每個視窗開著的聊天都不算未讀;關掉一個視窗不影響另一個視窗開著的(#41)")
    func chatsVisibleInSeveralWindows() async {
        let clock = MarkerClock(Self.t0)
        let studio = await Self.host(Self.studio, clock: clock)
        let lab = await Self.host(Self.lab, name: "Lab", clock: clock)
        let model = Self.merged([studio, lab])
        await model.load()
        let first = ChatRoute(host: Self.studio, paneID: "w1:p6")
        let second = ChatRoute(host: Self.lab, paneID: "w1:p6")
        model.chatAppeared(first)
        model.chatAppeared(second)
        let later = ["w1:p6": Self.preview(Self.t0.addingTimeInterval(300))]
        studio.source.list.previews = later
        lab.source.list.previews = later

        #expect(Self.row("w1:p6", host: Self.studio, in: model)?.isUnread == false, "先開的視窗被後開的蓋掉")
        #expect(Self.row("w1:p6", host: Self.lab, in: model)?.isUnread == false)

        model.chatDisappeared(second)
        #expect(Self.row("w1:p6", host: Self.studio, in: model)?.isUnread == false, "關掉另一個視窗後，這個視窗開著的變成未讀")
    }

    @Test("未讀以主機 + session 為鍵：兩台主機有相同 session,讀了一台不影響另一台;重新啟動後仍記得")
    func readMarkersAreScopedByHostAndPersisted() async {
        let defaults = UserDefaults(suiteName: "UnreadPinnedTests.markers.\(UUID())")!
        let stores = UserDefaultsHostChatPreferencesStore(defaults: defaults)
        let clock = MarkerClock(Self.t0)
        let studio = await Self.host(Self.studio, clock: clock, preferences: stores.store(for: Self.studio))
        let lab = await Self.host(Self.lab, name: "Lab", clock: clock, preferences: stores.store(for: Self.lab))
        let model = Self.merged([studio, lab])
        await model.load()
        let preview = ["w1:p6": Self.preview(Self.t0.addingTimeInterval(-60))]
        studio.source.list.previews = preview
        lab.source.list.previews = preview

        model.chatAppeared(ChatRoute(host: Self.studio, paneID: "w1:p6"))
        model.chatDisappeared(ChatRoute(host: Self.studio, paneID: "w1:p6"))

        #expect(Self.row("w1:p6", host: Self.studio, in: model)?.isUnread == false)
        #expect(Self.row("w1:p6", host: Self.lab, in: model)?.isUnread == true, "讀了一台主機，另一台同 session 也變已讀")

        let relaunched = UserDefaultsHostChatPreferencesStore(defaults: defaults, legacyKey: "unused")
        #expect(relaunched.store(for: Self.studio).load().opened[Self.sessionP6] == Self.t0)
        #expect(relaunched.store(for: Self.lab).load().opened[Self.sessionP6] == nil)
    }

    @Test("舊版只有釘選、靜音的偏好仍讀得出來(沒有開啟紀錄)")
    func decodesPreferencesWithoutOpenedMarkers() throws {
        let data = Data(#"{"pinned":{"s1":0},"muted":["s2"]}"#.utf8)
        let preferences = try JSONDecoder().decode(ChatPreferences.self, from: data)
        #expect(preferences.pinned["s1"] != nil)
        #expect(preferences.muted == ["s2"])
        #expect(preferences.opened.isEmpty)
    }

    // MARK: - 已釘選

    @Test("四組依序：已釘選、需要你、工作中、閒置;已釘選依釘選時間舊→新")
    func pinnedGroupComesFirstOrderedByPinTime() async {
        let clock = MarkerClock(Self.t0)
        let studio = await Self.host(Self.studio, clock: clock, snapshots: [{
            SnapshotEdit.agent("w1:p6", in: &$0) { $0["agent_status"] = "blocked" }
        }])
        let model = Self.merged([studio])
        await model.load()

        studio.source.actions.togglePin(sessionID: Self.sessionB)
        clock.now = Self.t0.addingTimeInterval(10)
        studio.source.actions.togglePin(sessionID: Self.sessionP6)

        #expect(model.sections.map(\.group) == [.pinned, .working])
        #expect(model.sections.first?.rows.map(\.paneID) == ["w1:pB", "w1:p6"])
        #expect(model.sections.first?.rows.allSatisfy(\.isPinned) == true)
        #expect(model.sections.last?.rows.map(\.paneID) == ["w1:pA"])
    }

    @Test("已釘選的列不因狀態改變而跳組")
    func pinnedRowStaysPinnedWhenStatusChanges() async {
        let clock = MarkerClock(Self.t0)
        let studio = await Self.host(Self.studio, clock: clock, snapshots: [nil, {
            SnapshotEdit.agent("w1:p6", in: &$0) { $0["agent_status"] = "blocked" }
        }])
        let model = Self.merged([studio])
        await model.load()
        studio.source.actions.togglePin(sessionID: Self.sessionP6)

        await model.load()

        #expect(model.sections.first?.group == .pinned)
        #expect(model.sections.first?.rows.map(\.paneID) == ["w1:p6"])
        #expect(Self.row("w1:p6", in: model)?.status == .blocked, "狀態照實顯示，只是不換組")
        #expect(!model.sections.contains { $0.group == .needsYou })
    }

    @Test("已釘選跨主機合併，依釘選時間排序")
    func pinnedGroupMergesHosts() async {
        let clock = MarkerClock(Self.t0)
        let studio = await Self.host(Self.studio, clock: clock)
        let lab = await Self.host(Self.lab, name: "Lab", clock: clock)
        let model = Self.merged([studio, lab])
        await model.load()

        lab.source.actions.togglePin(sessionID: Self.sessionP6)
        clock.now = Self.t0.addingTimeInterval(5)
        studio.source.actions.togglePin(sessionID: Self.sessionP6)

        #expect(model.sections.first?.rows.map(\.id) == [
            "\(Self.lab.storedValue)/w1:p6", "\(Self.studio.storedValue)/w1:p6",
        ])
    }

    @Test("列帶釘選、靜音旗標(標題後的小圖示)")
    func rowsCarryPinAndMuteFlags() async {
        let clock = MarkerClock(Self.t0)
        let studio = await Self.host(Self.studio, clock: clock)
        let model = Self.merged([studio])
        await model.load()

        studio.source.actions.toggleMute(sessionID: Self.sessionA)

        #expect(Self.row("w1:pA", in: model)?.isMuted == true)
        #expect(Self.row("w1:pA", in: model)?.isPinned == false)
        #expect(Self.row("w1:pB", in: model)?.isMuted == false)
    }

    // MARK: - 需處理數量

    @Test("需處理的 workspace 數：有 blocked 或未讀的 workspace 各算一次")
    func attentionCountsWorkspaces() async {
        let clock = MarkerClock(Self.t0)
        let studio = await Self.host(Self.studio, clock: clock, snapshots: [{
            // w1:pA blocked、w1:pB 移到 w2 並變 idle(之後給它未讀回覆)、w1:p6 留在 w1。
            SnapshotEdit.agent("w1:pA", in: &$0) { $0["agent_status"] = "blocked" }
            SnapshotEdit.agent("w1:pB", in: &$0) {
                $0["agent_status"] = "idle"
                $0["workspace_id"] = "w2"
            }
        }])
        let model = Self.merged([studio])
        await model.load()
        #expect(model.attentionCount == 1, "只有 w1 有 blocked")

        studio.source.list.previews = [
            "w1:pB": Self.preview(Self.t0),
            "w1:p6": Self.preview(Self.t0),
        ]
        #expect(model.attentionCount == 2, "w1(blocked + 未讀)算一次、w2(未讀)一次")
    }

    @Test("需處理數量不算目前開著的聊天：開的是其中一個 agent,只算兄弟的 blocked")
    func attentionExcludesVisibleChat() async {
        let clock = MarkerClock(Self.t0)
        let studio = await Self.host(Self.studio, clock: clock, snapshots: [{
            SnapshotEdit.agent("w1:pA", in: &$0) { $0["agent_status"] = "blocked" }
            SnapshotEdit.agent("w1:pB", in: &$0) { $0["agent_status"] = "idle" }
        }])
        let model = Self.merged([studio])
        await model.load()
        studio.source.list.previews = ["w1:pB": Self.preview(Self.t0)]

        model.chatAppeared(ChatRoute(host: Self.studio, paneID: "w1:pA"))
        #expect(model.attentionCount == 0, "開著的是 blocked 的那個;兄弟只有未讀(不算)")

        model.chatDisappeared(ChatRoute(host: Self.studio, paneID: "w1:pA"))
        model.chatAppeared(ChatRoute(host: Self.studio, paneID: "w1:pB"))
        #expect(model.attentionCount == 1, "兄弟 w1:pA blocked 仍要算")
    }

    // MARK: - 聊天 tab 的「需要你」數

    @Test("聊天 tab badge:所有主機的 blocked Agent 各算一個(不算未讀,不受主機篩選影響);排除指定的聊天")
    func needsYouCountsBlockedAgentsOnly() async {
        let clock = MarkerClock(Self.t0)
        let studio = await Self.host(Self.studio, clock: clock, snapshots: [{
            SnapshotEdit.agent("w1:pA", in: &$0) { $0["agent_status"] = "blocked" }
            SnapshotEdit.agent("w1:pB", in: &$0) { $0["agent_status"] = "blocked" }
        }])
        let model = Self.merged([studio])
        await model.load()
        studio.source.list.previews = ["w1:p6": Self.preview(Self.t0)]

        #expect(model.needsYouCount() == 2, "兩個 blocked;p6 只是未讀,不算")
        #expect(model.needsYouCount(excluding: ChatRoute(host: Self.studio, paneID: "w1:pA")) == 1, "對話返回鈕旁的「另外 N 個」")

        model.currentHost = Self.lab
        #expect(model.needsYouCount() == 2, "主機篩選不影響 tab badge")
    }

    // MARK: - 剛關閉的 Tab

    @Test("關閉 Tab 成功後，列表馬上拿掉那一列，即使重讀到的快照還有它(SSH 重讀慢時不會出現「關了還在、再關一次 tab not found」)")
    func closedTabDisappearsBeforeSnapshotCatchesUp() async {
        let clock = MarkerClock(Self.t0)
        let studio = await Self.host(Self.studio, clock: clock)
        let model = Self.merged([studio])
        await model.load()
        let tabKeys = { model.spacesSections.flatMap(\.tabs).map(\.key) }
        #expect(tabKeys().contains("w1:tA"))

        await studio.fake.expect(Self.bridge, reply: FakeReply(stdout: Data(#"{"id":"purrdr:tab.close","result":{"type":"ok"}}"#.utf8 + [0x0A]), trigger: .afterStdinLine))
        await studio.source.actions.closeTab(tabID: "w1:tA", sessionIDs: [])

        #expect(studio.source.list.snapshot?.tabs.contains { $0.id == "w1:tA" } == true, "快照還沒追上")
        #expect(!tabKeys().contains("w1:tA"))
        #expect(tabKeys().contains("w1:t6"), "其他 Tab 不受影響")
    }
}
