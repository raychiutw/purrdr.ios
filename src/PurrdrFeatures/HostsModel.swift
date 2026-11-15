import Foundation
import Observation
import PurrdrCore

public enum HostSelection: Hashable, Sendable {
    case demo
    case host(UUID)
}

public struct HostRow: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var subtitle: String
    public var session: String?
    public var isSelected: Bool

    public init(id: UUID, title: String, subtitle: String, session: String?, isSelected: Bool) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.session = session
        self.isSelected = isSelected
    }
}

/// 主機清單與選取中主機(行為規格 F1.1、F1.3)。選取中主機決定 Agent 列表讀哪台。
///
/// 選取目前只存在記憶體，啟動時選第一台已存主機，沒有就選 Demo 主機;多主機管理與持久化在 #10。
@MainActor
@Observable
public final class HostsModel {
    public private(set) var selection: HostSelection = .demo
    public private(set) var hosts: [HostConfiguration] = []
    public private(set) var agentList: AgentListModel
    /// 選取中主機的 Workspace 操作(釘選、靜音、重新命名、關閉)。
    public private(set) var workspaceActions: WorkspaceActionsModel
    /// 選取中主機的 Claude 用量(列表底部，行為規格 F18)。同意以主機為單位記住。
    public private(set) var claudeUsage: ClaudeUsageModel
    /// 選取中主機的推播開關(#29)。
    public private(set) var push: PushModel
    /// 讀不到已存主機時的說明。
    public private(set) var loadError: String?

    private let store: any HostStore
    private let demoChannel: any HostChannel
    private let makeChannel: @MainActor (SSHEndpoint, HostKeyFingerprint?) -> any HostChannel
    private let conversationCache: any ConversationCache
    private let preferences: any ChatPreferencesStore
    /// Demo 主機的主機寫入同意(Demo 不持久化，行為規格 F21)。
    private let demoConsent: any HostWriteConsentStore
    /// 真主機的主機寫入同意(以主機 id 為鍵);移除主機時清除。
    private let hostConsent: any HostWriteConsentStore
    /// 推播(後台、權限、配對紀錄);`nil` 時沒有推播。
    private let pushService: PushService?
    /// 輸入列草稿：離開聊天保留、重開 app 不保留(行為規格 F6.2)。所有主機共用，以 pane id 為鍵(同 `preferences`)。
    private let drafts = DraftStore()
    /// 對話作答的觸覺(composition root 注入系統觸覺;測試不播放)。
    public var haptics: any Haptics = SilentHaptics()
    private var channel: any HostChannel
    private var client: HerdrClient
    private var transcripts: TranscriptReader
    private var terminals: PaneTerminalClient

    /// - Parameters:
    ///   - conversationCache: 對話快取(所有主機共用;快取以 session 為鍵)。
    ///   - preferences: 釘選、靜音等本機偏好(目前所有主機共用，以 pane id 為鍵;多主機合併時要加上主機身分)。
    public init(
        store: any HostStore, demoChannel: any HostChannel, conversationCache: any ConversationCache = InMemoryConversationCache(),
        preferences: any ChatPreferencesStore = InMemoryChatPreferencesStore(),
        demoConsent: any HostWriteConsentStore = InMemoryHostWriteConsentStore(),
        hostConsent: any HostWriteConsentStore = InMemoryHostWriteConsentStore(),
        push pushService: PushService? = nil,
        makeChannel: @escaping @MainActor (SSHEndpoint, HostKeyFingerprint?) -> any HostChannel
    ) {
        self.store = store
        self.demoChannel = demoChannel
        self.makeChannel = makeChannel
        self.conversationCache = conversationCache
        self.preferences = preferences
        self.demoConsent = demoConsent
        self.hostConsent = hostConsent
        self.pushService = pushService
        channel = demoChannel
        let client = HerdrClient(channel: demoChannel)
        let transcripts = TranscriptReader(channel: demoChannel)
        self.client = client
        self.transcripts = transcripts
        terminals = PaneTerminalClient(channel: demoChannel)
        let agentList = AgentListModel(client: client, transcripts: transcripts)
        self.agentList = agentList
        workspaceActions = WorkspaceActionsModel(client: client, preferences: preferences, refresh: { await agentList.load() })
        claudeUsage = ClaudeUsageModel(host: ClaudeUsageHost(channel: demoChannel), hostID: Self.demoID, consent: demoConsent)
        push = PushModel(service: pushService, hostID: nil, channel: demoChannel, herdr: HerdrInstallation()) { preferences.load().muted }
        connectMutes()
    }

    /// 靜音改變時，推播開著就改寫主機上的靜音清單。
    private func connectMutes() {
        let push = push
        workspaceActions.mutedChanged = { muted in Task { await push.syncMuted(muted) } }
    }

    /// Demo 主機在同意紀錄裡的主機 id。
    static let demoID = "demo"

    /// 選取中主機上某個 Pane 的終端機 model(pane id、標題)。
    public func terminal(paneID: String, title: String) -> PaneTerminalModel {
        PaneTerminalModel(client: terminals, paneID: paneID, title: title)
    }

    /// 選取中主機上某個 Agent 的對話 model(pane id、列表看到的 session)。
    public func conversation(paneID: String, sessionID: String?) -> ConversationModel {
        ConversationModel(client: client, transcripts: transcripts, paneID: paneID, knownSessionID: sessionID, cache: conversationCache,
            drafts: drafts, slashDiscovery: ClaudeSlashDiscovery(channel: channel), haptics: haptics)
    }

    public var rows: [HostRow] {
        hosts.map { host in
            HostRow(
                id: host.id, title: host.name,
                subtitle: "\(host.endpoint.username)@\(host.endpoint.host):\(host.endpoint.port)",
                session: host.herdr.session, isSelected: selection == .host(host.id))
        }
    }

    /// 選取中的主機(Demo 時為 `nil`)。
    public var selectedHost: HostConfiguration? {
        guard case .host(let id) = selection else { return nil }
        return hosts.first { $0.id == id }
    }

    /// 從儲存讀主機清單。
    public func load() {
        do {
            hosts = try store.loadHosts().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            loadError = nil
        } catch {
            loadError = "Couldn’t read saved hosts on this device. \(error.localizedDescription)"
        }
        select(hosts.first.map { .host($0.id) } ?? .demo)
    }

    /// 選取主機：關掉舊主機的連線，Agent 列表改讀新主機。
    public func select(_ selection: HostSelection) {
        let host: HostConfiguration?
        switch selection {
        case .demo: host = nil
        case .host(let id):
            guard let found = hosts.first(where: { $0.id == id }) else { return }
            host = found
        }
        let previous = channel
        if let host {
            channel = makeChannel(host.endpoint, host.hostKeyPin)
            client = HerdrClient(channel: channel, herdr: host.herdr)
            terminals = PaneTerminalClient(channel: channel, herdr: host.herdr)
        } else {
            channel = demoChannel
            client = HerdrClient(channel: demoChannel)
            terminals = PaneTerminalClient(channel: demoChannel)
        }
        transcripts = TranscriptReader(channel: channel)
        let agentList = AgentListModel(client: client, transcripts: transcripts)
        self.agentList = agentList
        workspaceActions = WorkspaceActionsModel(client: client, preferences: preferences, refresh: { await agentList.load() })
        claudeUsage = ClaudeUsageModel(
            host: ClaudeUsageHost(channel: channel), hostID: host?.id.uuidString ?? Self.demoID,
            consent: host == nil ? demoConsent : hostConsent)
        let preferences = preferences
        push = PushModel(
            service: pushService, hostID: host?.id.uuidString, channel: channel, herdr: host?.herdr ?? HerdrInstallation()
        ) { preferences.load().muted }
        connectMutes()
        self.selection = selection
        Task { await previous.disconnect() }
    }

    /// 新增或編輯主機並儲存後：重讀清單並選取它(設定改了，連線一律重建)。
    public func didSave(_ host: HostConfiguration) {
        hosts = (try? store.loadHosts())?.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } ?? hosts
        select(.host(host.id))
    }

    /// 移除主機：從儲存刪除、清除這台主機的所有主機寫入同意(行為規格 F18),選取中就改選其他主機或 Demo。
    public func remove(_ id: UUID) throws {
        let removed = hosts.first { $0.id == id }
        try store.delete(id)
        if let removed {
            // 推播配對：不等待地刪掉主機上的配對並撤銷(行為規格 F14)。
            let hostChannel = selection == .host(id) ? channel : makeChannel(removed.endpoint, removed.hostKeyPin)
            pushService?.forget(hostID: id.uuidString, channel: hostChannel, herdr: removed.herdr)
        }
        hostConsent.revokeAll(host: id.uuidString)
        hosts.removeAll { $0.id == id }
        if selection == .host(id) {
            select(hosts.first.map { .host($0.id) } ?? .demo)
        }
    }

    /// 點了推播通知：切換到配對的主機，開該 Agent 的聊天。不認得的配對(主機已移除)不動。
    public func open(_ route: PushRoute, pairings: any PushPairingStore) {
        guard let hostID = pairings.host(forKeyHash: route.keyHash), let id = UUID(uuidString: hostID),
              hosts.contains(where: { $0.id == id }) else { return }
        if selection != .host(id) { select(.host(id)) }
        if let paneID = route.paneID { agentList.openedChat = paneID }
    }

    /// 點了推播通知(用 app 的推播紀錄)。
    public func open(_ route: PushRoute) {
        guard let pushService else { return }
        open(route, pairings: pushService.store)
    }

    /// 新增主機(`editing` 為 `nil`)或編輯既有主機的畫面 model。
    public func makeEditor(editing: HostConfiguration? = nil) -> HostEditorModel {
        HostEditorModel(store: store, editing: editing, makeChannel: makeChannel)
    }
}
