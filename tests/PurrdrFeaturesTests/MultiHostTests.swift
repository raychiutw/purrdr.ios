import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 依端點位址給每台主機各自的假主機(建立順序不影響)。
@MainActor
final class ChannelsByAddress {
    var hosts: [String: FakeHost]
    private(set) var made: [String] = []

    init(_ hosts: [String: FakeHost]) { self.hosts = hosts }

    func make(_ endpoint: SSHEndpoint, _ pin: HostKeyFingerprint?, _ credential: @escaping SSHCredentialProvider) -> any HostChannel {
        made.append(endpoint.host)
        return hosts[endpoint.host] ?? FakeHost()
    }
}

/// 多主機合併成同一個 Agent 列表(#39、#37 故事 1–6):每台主機各自連線、各自訂閱、各自錯誤;
/// 釘選、靜音、草稿、對話快取與列的身分都帶主機身分，兩台主機有相同 pane id、session 時不互相干擾。
@MainActor
@Suite("多主機合併列表")
struct MultiHostTests {
    static let pin = HostKeyFingerprint(stored: "COBpO4JIzmE5SXJiDiFEv8QW0IgLEE4H3vB2W6wHLww")!
    static let studio = HostConfiguration(
        name: "Studio", endpoint: SSHEndpoint(host: "studio", username: "demo"), operatingSystem: .macOS, hostKeyPin: pin)
    static let lab = HostConfiguration(
        name: "Lab", endpoint: SSHEndpoint(host: "lab", username: "demo"), operatingSystem: .linux, hostKeyPin: pin)
    static let bridge = HerdrCommand.bridge()
    /// 錄製 snapshot 裡的 session(兩台主機都回同一份錄製，所以 pane id 與 session 都相同)。
    static let sessionA = "00000000-0000-0000-0000-000000000002"
    static let timedOut = "The host didn’t answer in time. Make sure it’s awake and both devices are on your tailnet."

    static func model(
        _ channels: ChannelsByAddress, preferences: any HostChatPreferencesStore = InMemoryHostChatPreferencesStore(),
        icons: any HostIconStore = InMemoryHostIconStore()
    ) -> HostsModel {
        let store = MemoryHostStore()
        store.hosts = [studio, lab]
        return HostsModel(
            store: store, demoChannel: FakeHost(), preferences: preferences, hostIcons: icons, makeChannel: channels.make)
    }

    static func healthy() async -> FakeHost {
        let host = FakeHost()
        await host.expect(bridge, reply: .recorded("session.snapshot.ndjson"))
        return host
    }

    static func rows(_ model: HostsModel) -> [AgentRow] {
        model.agentList.sections.flatMap(\.rows)
    }

    @Test("所有主機的 Agent 在同一個列表;不同主機的同一個 pane id 各自一列，非選取中主機的副標開頭是主機名")
    func mergesHostsWithSamePaneIDs() async {
        let channels = ChannelsByAddress(["studio": await Self.healthy(), "lab": await Self.healthy()])
        let model = Self.model(channels)
        model.load()
        model.select(.host(Self.studio.id))

        await model.agentList.load()

        let rows = Self.rows(model)
        #expect(rows.count == 6)
        #expect(Set(rows.map(\.id)).count == 6, "不同主機的同一個 pane id 撞在一起")
        let studioRows = rows.filter { $0.host == .host(Self.studio.id) }
        let labRows = rows.filter { $0.host == .host(Self.lab.id) }
        #expect(studioRows.map(\.paneID).sorted() == ["w1:p6", "w1:pA", "w1:pB"])
        #expect(labRows.map(\.paneID).sorted() == ["w1:p6", "w1:pA", "w1:pB"])
        #expect(labRows.allSatisfy { $0.subtitle.hasPrefix("Lab · ") && $0.hostLabel?.name == "Lab" })
        #expect(studioRows.allSatisfy { !$0.subtitle.hasPrefix("Studio") && $0.hostLabel == nil })
        // 選取中主機的列在前。
        #expect(model.agentList.sections.first?.rows.first?.host == .host(Self.studio.id))
    }

    @Test("換選取中主機：不重新連線，只改排序與哪台標示主機名")
    func changingSelectionKeepsConnections() async {
        let channels = ChannelsByAddress(["studio": await Self.healthy(), "lab": await Self.healthy()])
        let model = Self.model(channels)
        model.load()
        await model.agentList.load()

        model.select(.host(Self.studio.id))
        model.select(.host(Self.lab.id))

        #expect(channels.made.sorted() == ["lab", "studio"], "換選取中主機不該重建連線")
        let rows = Self.rows(model)
        #expect(rows.count == 6, "換選取中主機後列不見了")
        #expect(rows.filter { $0.host == .host(Self.studio.id) }.allSatisfy { $0.subtitle.hasPrefix("Studio · ") })
        #expect(rows.filter { $0.host == .host(Self.lab.id) }.allSatisfy { $0.hostLabel == nil })
    }

    @Test("一台主機連不上不影響其他台：其他台的列照常顯示，列表下方是「主機名：原因」")
    func unreachableHostDoesNotAffectOthers() async {
        let lab = FakeHost()
        await lab.failConnection(with: SSHConnectionError.timedOut)
        let channels = ChannelsByAddress(["studio": await Self.healthy(), "lab": lab])
        let model = Self.model(channels)
        model.load()
        model.select(.host(Self.studio.id))

        await model.agentList.load()

        #expect(Self.rows(model).count == 3)
        #expect(Self.rows(model).allSatisfy { $0.host == .host(Self.studio.id) })
        #expect(model.agentList.failures == [HostFailure(host: .host(Self.lab.id), name: "Lab", message: Self.timedOut)])
        #expect(model.agentList.failures.first?.text == "Lab: \(Self.timedOut)")
        #expect(model.agentList.content == .list)
    }

    @Test("選取中主機連不上、但其他台有列時，不佔滿畫面：列照常顯示，錯誤在列表下方")
    func selectedHostErrorStaysBelowOtherHostsRows() async {
        let lab = FakeHost()
        await lab.failConnection(with: SSHConnectionError.timedOut)
        let model = Self.model(ChannelsByAddress(["studio": await Self.healthy(), "lab": lab]))
        model.load()
        model.select(.host(Self.lab.id))

        await model.agentList.load()

        #expect(model.agentList.content == .list)
        #expect(Self.rows(model).count == 3)
        #expect(model.agentList.failures.map(\.name) == ["Lab"])
    }

    @Test("選取中主機連不上、其他台讀到但沒有列時，錯誤留在列表的那台主機一行，不佔滿畫面(#221)")
    func selectedHostErrorStaysInItsRowWhenNothingToShow() async {
        let lab = FakeHost()
        await lab.failConnection(with: SSHConnectionError.timedOut)
        let studio = FakeHost()
        await studio.expect(Self.bridge, reply: .recorded("session.snapshot.ndjson") { SnapshotEdit.removeAgent("w1:pA", in: &$0)
            SnapshotEdit.removeAgent("w1:pB", in: &$0)
            SnapshotEdit.removeAgent("w1:p6", in: &$0)
        })
        let model = Self.model(ChannelsByAddress(["studio": studio, "lab": lab]))
        model.load()
        model.select(.host(Self.lab.id))

        await model.agentList.load()

        #expect(model.agentList.content == .list)
        #expect(model.agentList.failures.map(\.name) == ["Lab"])
    }

    @Test("即時更新：一台主機一直連不上(退避中)時，另一台照常讀取並訂閱")
    func liveUpdatesAreIndependentPerHost() async throws {
        let lab = FakeHost()
        await lab.failConnection(with: SSHConnectionError.timedOut)
        let studio = FakeHost()
        await studio.expect(Self.bridge, reply: .recorded("session.snapshot.ndjson"))
        await studio.expect(Self.bridge, reply: .recorded("events.subscribe.started.ndjson", keepsOpen: true))
        await studio.expect(Self.bridge, reply: .recorded("session.snapshot.ndjson"))
        let model = Self.model(ChannelsByAddress(["studio": studio, "lab": lab]))
        model.load()

        let task = Task { await model.agentList.run() }
        defer { task.cancel() }

        try await waitUntil { await studio.consumedAll(executions: 3) }
        try await waitUntil { await MainActor.run { !model.agentList.failures.isEmpty } }
        #expect(Self.rows(model).count == 3)
        #expect(model.agentList.failures.map(\.name) == ["Lab"])
    }

    @Test("釘選與靜音以主機分開：兩台主機有相同 session 時，釘選、靜音一台不影響另一台;重新啟動後仍在")
    func preferencesAreScopedByHost() {
        let defaults = UserDefaults(suiteName: "MultiHostTests.preferences.\(UUID())")!
        let channels = ChannelsByAddress([:])
        let model = Self.model(channels, preferences: UserDefaultsHostChatPreferencesStore(defaults: defaults))
        model.load()
        let studioActions = model.agentList.actions(for: .host(Self.studio.id))
        let labActions = model.agentList.actions(for: .host(Self.lab.id))

        studioActions?.togglePin(sessionID: Self.sessionA)
        studioActions?.toggleMute(sessionID: Self.sessionA)

        #expect(studioActions?.isPinned(sessionID: Self.sessionA) == true)
        #expect(labActions?.isPinned(sessionID: Self.sessionA) == false, "釘選套到另一台主機的同一個 session")
        #expect(labActions?.isMuted(sessionID: Self.sessionA) == false, "靜音套到另一台主機的同一個 session")

        let relaunched = Self.model(channels, preferences: UserDefaultsHostChatPreferencesStore(defaults: defaults))
        relaunched.load()
        #expect(relaunched.agentList.actions(for: .host(Self.studio.id))?.isPinned(sessionID: Self.sessionA) == true)
        #expect(relaunched.agentList.actions(for: .host(Self.lab.id))?.isPinned(sessionID: Self.sessionA) == false)
    }

    @Test("沒有主機身分的舊版釘選、靜音明確丟棄(無法判斷屬於哪台主機)")
    func legacyPreferencesAreDiscarded() throws {
        let defaults = UserDefaults(suiteName: "MultiHostTests.legacy.\(UUID())")!
        let legacy = ChatPreferences(pinned: [Self.sessionA: Date()], muted: [Self.sessionA])
        defaults.set(try JSONEncoder().encode(legacy), forKey: "chatPreferences")

        let store = UserDefaultsHostChatPreferencesStore(defaults: defaults)

        #expect(store.store(for: .host(Self.studio.id)).load() == ChatPreferences())
        #expect(defaults.data(forKey: "chatPreferences") == nil, "舊資料沒有清掉")
    }

    @Test("草稿以主機分開：另一台主機同一個 pane 的聊天不會帶出這台的草稿")
    func draftsAreScopedByHost() {
        let model = Self.model(ChannelsByAddress([:]))
        model.load()
        let paneID = "w1:pA"

        model.conversation(ChatRoute(host: .host(Self.studio.id), paneID: paneID), sessionID: Self.sessionA).draft = "studio draft"

        #expect(model.conversation(ChatRoute(host: .host(Self.lab.id), paneID: paneID), sessionID: Self.sessionA).draft == "")
        #expect(model.conversation(ChatRoute(host: .host(Self.studio.id), paneID: paneID), sessionID: Self.sessionA).draft == "studio draft")
    }

    @Test("對話快取以主機分開：刪除一台主機只清它的快取")
    func conversationCacheIsScopedByHost() async throws {
        let cache = InMemoryConversationCache()
        let store = MemoryHostStore()
        store.hosts = [Self.studio, Self.lab]
        let model = HostsModel(store: store, demoChannel: FakeHost(), conversationCache: cache, makeChannel: ChannelsByAddress([:]).make)
        model.load()
        let cached = CachedConversation(sessionID: Self.sessionA, messages: [], metadata: TranscriptMetadata(), path: "/t", cursor: 0, windowStart: 0)
        await model.conversationCache(for: .host(Self.studio.id)).save(cached, chatKey: "w1:pA")

        #expect(await model.conversationCache(for: .host(Self.lab.id)).load(chatKey: "w1:pA") == nil)
        await model.conversationCache(for: .host(Self.lab.id)).save(cached, chatKey: "w1:pA")
        try await model.delete(Self.lab.id)
        #expect(await model.conversationCache(for: .host(Self.studio.id)).load(chatKey: "w1:pA") == cached)
    }

    @Test("非選取中主機的聊天，標題列第一段是主機名;選取中主機的不顯示")
    func conversationHeaderNamesOtherHost() {
        let model = Self.model(ChannelsByAddress([:]))
        model.load()
        model.select(.host(Self.studio.id))

        let other = model.conversation(ChatRoute(host: .host(Self.lab.id), paneID: "w1:pA"), sessionID: nil)
        let selected = model.conversation(ChatRoute(host: .host(Self.studio.id), paneID: "w1:pA"), sessionID: nil)

        #expect(other.header.segments.first == "Lab")
        #expect(!selected.header.segments.contains("Studio"))
    }

    @Test("已開啟的聊天：換選取中主機後，標題列的主機名跟著更新;主機改名也跟著改")
    func openedConversationHeaderFollowsSelection() throws {
        let model = Self.model(ChannelsByAddress([:]))
        model.load()
        model.select(.host(Self.studio.id))
        let lab = model.conversation(ChatRoute(host: .host(Self.lab.id), paneID: "w1:pA"), sessionID: nil)
        let studio = model.conversation(ChatRoute(host: .host(Self.studio.id), paneID: "w1:pA"), sessionID: nil)

        model.select(.host(Self.lab.id))

        #expect(!lab.header.segments.contains("Lab"), "換成選取中主機後不該再標示主機名")
        #expect(studio.header.segments.first == "Studio")
        try model.rename(Self.studio.id, to: "Studio 2")
        #expect(studio.header.segments.first == "Studio 2")
    }

    @Test("主機圖示只存本機，以主機 id 為鍵;非選取中主機的列帶它的圖示")
    func hostIconsAreLocalPerHost() async {
        let defaults = UserDefaults(suiteName: "MultiHostTests.icons.\(UUID())")!
        let channels = ChannelsByAddress(["studio": await Self.healthy(), "lab": await Self.healthy()])
        let model = Self.model(channels, icons: UserDefaultsHostIconStore(defaults: defaults))
        model.load()
        model.select(.host(Self.studio.id))

        model.setIcon(.rack, for: Self.lab.id)
        await model.agentList.load()

        #expect(model.rows.first { $0.id == Self.lab.id }?.icon == .rack)
        #expect(model.rows.first { $0.id == Self.studio.id }?.icon == .desktop, "沒選圖示的主機用預設圖示")
        #expect(Self.rows(model).filter { $0.host == .host(Self.lab.id) }.allSatisfy { $0.hostLabel?.icon == .rack })
        #expect(UserDefaultsHostIconStore(defaults: defaults).icon(for: Self.lab.id) == .rack)
    }

    @Test("機架圖示(GLOSSARY 避免 Server):選單名稱是 Rack;裝置上舊版存的 server 讀成機架")
    func rackIconReadsLegacyServer() {
        let defaults = UserDefaults(suiteName: "MultiHostTests.rack.\(UUID())")!
        defaults.set([Self.lab.id.uuidString: "server"], forKey: "hostIcons")
        let store = UserDefaultsHostIconStore(defaults: defaults)

        #expect(store.icon(for: Self.lab.id)?.rawValue == "rack")
        #expect(store.icon(for: Self.lab.id)?.title == "Rack")
        #expect(HostIcon.allCases.map(\.rawValue).contains("server") == false)
    }

    @Test("點通知：開配對主機上的聊天，不改選取中主機")
    func pushOpensChatOnPairedHostWithoutChangingSelection() {
        let model = Self.model(ChannelsByAddress([:]))
        model.load()
        model.select(.host(Self.studio.id))
        let pairings = InMemoryPushPairingStore()
        pairings.setKeyHash("abc", forHost: Self.lab.id.uuidString)

        model.open(PushRoute(keyHash: "abc", paneID: "w1:pA"), pairings: pairings)

        #expect(model.selection == .host(Self.studio.id))
        #expect(model.agentList.openedChat == ChatRoute(host: .host(Self.lab.id), paneID: "w1:pA"))
    }
}

@Suite("列左側的 agent 種類圖示")
struct AgentKindSymbolTests {
    @Test("每種 agent 有自己的圖示，不認得的種類用終端機")
    func symbolsDifferByKind() {
        let kinds = ["claude", "codex", "grok", "agy", "gemini", "pi", "omp", "open_code", "github_copilot"]
        let symbols = kinds.map(AgentKindSymbol.name(for:))
        #expect(Set(symbols).count == kinds.count, "不同種類的圖示重複:\(symbols)")
        #expect(AgentKindSymbol.name(for: "antigravity") == AgentKindSymbol.name(for: "agy"))
        #expect(AgentKindSymbol.name(for: "something-new") == "terminal")
        #expect(!symbols.contains("terminal"))
    }
}
