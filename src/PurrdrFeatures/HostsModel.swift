import Foundation
import Observation
import PurrdrCore

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

/// 管理主機時的錯誤。
public enum HostManagementError: Error, Equatable {
    case emptyName
    case notFound
}

/// 主機清單與選取中主機(行為規格 F1.1、F1.3)。選取中主機決定 Agent 列表讀哪台。
///
/// - 每台主機各自一條主機通道(第一次用到才建立，切換選取不關閉);#39 多主機合併列表時每台主機各自連線。
/// - 選取存在本機(`HostSelectionStore`),重新啟動後選回同一台;存的主機已刪除時選第一台，沒有主機就選 Demo 主機。
/// - 編輯、刪除主機時關閉那台主機的連線;刪除也清掉它的對話快取。
@MainActor
@Observable
public final class HostsModel {
    public private(set) var selection: HostSelection = .demo
    public private(set) var hosts: [HostConfiguration] = []
    public private(set) var agentList: AgentListModel
    /// 選取中主機的 Workspace 操作(釘選、靜音、重新命名、關閉)。
    public private(set) var workspaceActions: WorkspaceActionsModel
    /// 讀不到已存主機時的說明。
    public private(set) var loadError: String?

    private let store: any HostStore
    private let selectionStore: any HostSelectionStore
    private let demoChannel: any HostChannel
    private let makeChannel: @MainActor (SSHEndpoint, HostKeyFingerprint?) -> any HostChannel
    private let conversationCache: any ConversationCache
    private let preferences: any ChatPreferencesStore
    /// 已建立的主機通道(以主機 id)。
    private var channels: [UUID: any HostChannel] = [:]
    private var client: HerdrClient
    private var transcripts: TranscriptReader
    private var terminals: PaneTerminalClient

    /// - Parameters:
    ///   - conversationCache: 對話快取(所有主機共用一個存放處，key 依主機分開)。
    ///   - preferences: 釘選、靜音等本機偏好(以 session id 為鍵;session id 跨主機不重複)。
    ///   - selectionStore: 選取中主機的存放處。
    public init(
        store: any HostStore, demoChannel: any HostChannel, conversationCache: any ConversationCache = InMemoryConversationCache(),
        preferences: any ChatPreferencesStore = InMemoryChatPreferencesStore(),
        selectionStore: any HostSelectionStore = InMemoryHostSelectionStore(),
        makeChannel: @escaping @MainActor (SSHEndpoint, HostKeyFingerprint?) -> any HostChannel
    ) {
        self.store = store
        self.selectionStore = selectionStore
        self.demoChannel = demoChannel
        self.makeChannel = makeChannel
        self.conversationCache = conversationCache
        self.preferences = preferences
        let client = HerdrClient(channel: demoChannel)
        let transcripts = TranscriptReader(channel: demoChannel)
        self.client = client
        self.transcripts = transcripts
        terminals = PaneTerminalClient(channel: demoChannel)
        let agentList = AgentListModel(client: client, transcripts: transcripts)
        self.agentList = agentList
        workspaceActions = WorkspaceActionsModel(client: client, preferences: preferences, refresh: { await agentList.load() })
    }

    /// 選取中主機上某個 Pane 的終端機 model(pane id、標題)。
    public func terminal(paneID: String, title: String) -> PaneTerminalModel {
        PaneTerminalModel(client: terminals, paneID: paneID, title: title)
    }

    /// 選取中主機上某個 Agent 的對話 model(pane id、列表看到的 session)。
    public func conversation(paneID: String, sessionID: String?) -> ConversationModel {
        ConversationModel(
            client: client, transcripts: transcripts, paneID: paneID, knownSessionID: sessionID, cache: conversationCache(for: selection))
    }

    /// 某台主機的對話快取(key 加上主機身分)。
    public func conversationCache(for selection: HostSelection) -> any ConversationCache {
        HostScopedConversationCache(base: conversationCache, scope: selection.storedValue)
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

    /// 從儲存讀主機清單，選回上次選取的主機。
    public func load() {
        do {
            hosts = try sortedHosts()
            loadError = nil
        } catch {
            loadError = "Couldn’t read saved hosts on this device. \(error.localizedDescription)"
        }
        select(validSelection(selectionStore.load()))
    }

    /// 選取主機並存起來：Agent 列表改讀那台(換主機時整個列表重建)。其他主機的連線不關閉。
    public func select(_ selection: HostSelection) {
        let channel: any HostChannel
        let herdr: HerdrInstallation
        switch selection {
        case .demo:
            channel = demoChannel
            herdr = HerdrInstallation()
        case .host(let id):
            guard let host = hosts.first(where: { $0.id == id }) else { return }
            channel = self.channel(for: host)
            herdr = host.herdr
        }
        client = HerdrClient(channel: channel, herdr: herdr)
        terminals = PaneTerminalClient(channel: channel, herdr: herdr)
        transcripts = TranscriptReader(channel: channel)
        let agentList = AgentListModel(client: client, transcripts: transcripts)
        self.agentList = agentList
        workspaceActions = WorkspaceActionsModel(client: client, preferences: preferences, refresh: { await agentList.load() })
        self.selection = selection
        selectionStore.save(selection)
    }

    /// 新增或編輯主機並儲存後：重讀清單並選取它。設定改了，那台主機的連線一律關閉重建。
    public func didSave(_ host: HostConfiguration) {
        hosts = (try? sortedHosts()) ?? hosts
        dropChannel(of: host.id)
        select(.host(host.id))
    }

    /// 重新命名：只改名稱，連線與選取不變。
    public func rename(_ id: UUID, to name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw HostManagementError.emptyName }
        guard var host = hosts.first(where: { $0.id == id }) else { throw HostManagementError.notFound }
        host.name = name
        try store.save(host)
        hosts = (try? sortedHosts()) ?? hosts
    }

    /// 刪除主機(使用者刻意的動作，不另外確認):刪掉此裝置上的設定與 host key pin、關閉連線、清掉對話快取。
    /// 主機本身不受影響。刪的是選取中主機時，改選第一台剩下的主機(沒有就選 Demo 主機)並存起來。
    public func delete(_ id: UUID) async throws {
        try store.delete(id)
        hosts.removeAll { $0.id == id }
        let channel = channels.removeValue(forKey: id)
        if selection == .host(id) { select(validSelection(nil)) }
        await conversationCache.removeAll(chatKeyPrefix: HostScopedConversationCache.prefix(scope: HostSelection.host(id).storedValue))
        await channel?.disconnect()
    }

    /// 主機的分享連結(QR code 內容)。不含任何祕密。
    public func shareLink(for id: UUID) -> URL? {
        hosts.first { $0.id == id }.map(HostShareLink.url(for:))
    }

    /// 新增主機(`editing` 為 `nil`)或編輯既有主機的畫面 model。
    public func makeEditor(editing: HostConfiguration? = nil) -> HostEditorModel {
        HostEditorModel(store: store, editing: editing, makeChannel: makeChannel)
    }

    /// 從主機分享連結匯入：帶入欄位的新增主機編輯器。連結不合法時丟 `HostShareLinkError`。
    public func makeImportEditor(_ url: URL) throws -> HostEditorModel {
        HostEditorModel(store: store, importing: try HostShareLink.decode(url), makeChannel: makeChannel)
    }

    // MARK: - 內部

    private func sortedHosts() throws -> [HostConfiguration] {
        try store.loadHosts().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func validSelection(_ stored: HostSelection?) -> HostSelection {
        switch stored {
        case .demo?: return .demo
        case .host(let id)? where hosts.contains(where: { $0.id == id }): return .host(id)
        default: return hosts.first.map { .host($0.id) } ?? .demo
        }
    }

    private func channel(for host: HostConfiguration) -> any HostChannel {
        if let channel = channels[host.id] { return channel }
        let channel = makeChannel(host.endpoint, host.hostKeyPin)
        channels[host.id] = channel
        return channel
    }

    private func dropChannel(of id: UUID) {
        guard let channel = channels.removeValue(forKey: id) else { return }
        Task { await channel.disconnect() }
    }
}
