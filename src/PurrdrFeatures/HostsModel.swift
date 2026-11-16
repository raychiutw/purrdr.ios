import Foundation
import Observation
import PurrdrCore

public struct HostRow: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var subtitle: String
    public var session: String?
    public var isSelected: Bool
    /// 使用者替主機選的圖示(只存本機);沒選過是預設圖示。
    public var icon: HostIcon

    public init(id: UUID, title: String, subtitle: String, session: String?, isSelected: Bool, icon: HostIcon = .default) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.session = session
        self.isSelected = isSelected
        self.icon = icon
    }
}

/// 管理主機時的錯誤。
public enum HostManagementError: Error, Equatable {
    case emptyName
    case notFound
}

/// 主機清單與選取中主機(行為規格 F1.1、F1.3;#39)。
///
/// - 所有主機的 Agent 合併在同一個列表(`agentList`):每台主機各自一條主機通道、各自的 herdr client、
///   列表、列操作、草稿與推播開關(`HostMember`);一台連不上不影響其他台。
/// - 選取中主機只決定新聊天開在哪裡、列表排序與哪些列標示主機名、Claude 用量與推播設定讀哪台;切換不關閉、不重建任何連線。
/// - Demo 主機只在沒有已存主機、或使用者選了它時出現在列表。
/// - 選取存在本機(`HostSelectionStore`),重新啟動後選回同一台;存的主機已刪除時選第一台，沒有主機就選 Demo 主機。
/// - 編輯、刪除主機時關閉那台主機的連線;刪除也清掉它的對話快取、釘選／靜音、草稿與圖示。
@MainActor
@Observable
public final class HostsModel {
    public private(set) var selection: HostSelection = .demo
    public private(set) var hosts: [HostConfiguration] = []
    /// 所有主機合併的 Agent 列表。
    public let agentList = MergedAgentListModel()
    /// 選取中主機的 Claude 用量(列表底部，行為規格 F18)。同意以主機為單位記住。
    public private(set) var claudeUsage: ClaudeUsageModel
    /// 選取中主機的 Codex 啟動器(設定頁，行為規格 §4.2)。同意以主機為單位記住。
    public private(set) var codexLauncher: CodexLauncherModel
    /// 讀不到已存主機時的說明。
    public private(set) var loadError: String?
    /// Tailscale SSH check mode 的提示。所有主機通道共用;composition root 把它的 `observer` 交給主機通道。
    public let tailscaleCheck: TailscaleCheckModel
    /// 使用者新增、修改、刪除主機時通知(主機同步)。
    public weak var changeRecorder: (any HostChangeRecorder)?
    /// 對話作答的觸覺(composition root 注入系統觸覺;測試不播放)。
    public var haptics: any Haptics = SilentHaptics()

    private let store: any HostStore
    private let selectionStore: any HostSelectionStore
    private let demoChannel: any HostChannel
    private let makeChannel: @MainActor (SSHEndpoint, HostKeyFingerprint?, @escaping SSHCredentialProvider) -> any HostChannel
    private let credentials: HostCredentials
    private let conversationCache: any ConversationCache
    private let preferences: any HostChatPreferencesStore
    private let hostIcons: any HostIconStore
    /// 主機圖示改了就遞增，讓依賴圖示的畫面(主機清單、主機鈕)重新計算。
    private var iconRevision = 0
    /// 已建立的主機通道(以主機 id)。
    private var channels: [UUID: any HostChannel] = [:]
    /// 列表上每台主機的連線與 model(以主機身分)。
    private var members: [HostSelection: HostMember] = [:]
    /// Demo 主機的主機寫入同意(Demo 不持久化，行為規格 F21)。
    private let demoConsent: any HostWriteConsentStore
    /// 真主機的主機寫入同意(以主機 id 為鍵);移除主機時清除。
    private let hostConsent: any HostWriteConsentStore
    /// 推播(後台、權限、配對紀錄);`nil` 時沒有推播。
    private let pushService: PushService?
    /// 送出圖片的手機副本(泡泡顯示用;所有主機共用，檔名不重複)。
    private let attachmentStore: any AttachmentStore

    /// - Parameters:
    ///   - conversationCache: 對話快取(所有主機共用一個存放處，key 依主機分開)。
    ///   - preferences: 釘選、靜音等本機偏好(依主機分開：同一個 session 值在不同主機是不同的聊天)。
    ///   - hostIcons: 使用者替主機選的圖示(只存本機)。
    ///   - selectionStore: 選取中主機的存放處。
    ///   - credentials: OpenSSH 主機的祕密與這支裝置的金鑰。
    ///   - makeChannel: 依端點、host key pin 與憑證來源建立主機通道(憑證在撥號時才讀)。
    public init(
        store: any HostStore, demoChannel: any HostChannel, conversationCache: any ConversationCache = InMemoryConversationCache(),
        preferences: any HostChatPreferencesStore = InMemoryHostChatPreferencesStore(),
        hostIcons: any HostIconStore = InMemoryHostIconStore(),
        selectionStore: any HostSelectionStore = InMemoryHostSelectionStore(),
        demoConsent: any HostWriteConsentStore = InMemoryHostWriteConsentStore(),
        hostConsent: any HostWriteConsentStore = InMemoryHostWriteConsentStore(), credentials: HostCredentials = HostCredentials(),
        push pushService: PushService? = nil, tailscaleCheck: TailscaleCheckModel? = nil,
        attachmentStore: any AttachmentStore = FileAttachmentStore.app(),
        makeChannel: @escaping @MainActor (SSHEndpoint, HostKeyFingerprint?, @escaping SSHCredentialProvider) -> any HostChannel
    ) {
        self.store = store
        self.selectionStore = selectionStore
        self.demoChannel = demoChannel
        self.makeChannel = makeChannel
        self.credentials = credentials
        self.conversationCache = conversationCache
        self.preferences = preferences
        self.hostIcons = hostIcons
        self.demoConsent = demoConsent
        self.hostConsent = hostConsent
        self.pushService = pushService
        self.tailscaleCheck = tailscaleCheck ?? TailscaleCheckModel()
        self.attachmentStore = attachmentStore
        claudeUsage = ClaudeUsageModel(host: ClaudeUsageHost(channel: demoChannel), hostID: Self.demoID, consent: demoConsent)
        codexLauncher = CodexLauncherModel(host: CodexLauncherHost(channel: demoChannel), hostID: Self.demoID, consent: demoConsent)
        rebuildMembers()
    }

    /// Demo 主機在同意紀錄裡的主機 id。
    static let demoID = "demo"

    /// 選取中主機的 herdr client(設定頁讀 herdr 版本用)。
    public var herdrClient: HerdrClient { member(for: selection).client }
    /// 選取中主機的推播開關(#29)。
    public var push: PushModel { member(for: selection).push }

    /// 某台主機上某個 Pane 的終端機 model(標題)。
    public func terminal(_ route: ChatRoute, title: String) -> PaneTerminalModel {
        PaneTerminalModel(client: member(for: route.host).terminals, paneID: route.paneID, title: title)
    }

    /// 選取中主機的登入 Shell(標題是主機名稱;Demo 主機是回顯的 shell)。
    public func loginShell() -> LoginShellModel {
        LoginShellModel(channel: member(for: selection).channel, title: name(of: selection))
    }

    /// 選取中主機的檔案瀏覽(從家目錄開始)。
    public func folderBrowser() -> FolderBrowserModel {
        FolderBrowserModel(folders: HostFolders(channel: member(for: selection).channel), hostName: name(of: selection))
    }

    /// 某台主機上某個 Agent 的對話 model(列表看到的 session)。非選取中主機的聊天在標題列帶主機名(#44)。
    public func conversation(_ route: ChatRoute, sessionID: String?) -> ConversationModel {
        let member = member(for: route.host)
        return ConversationModel(
            client: member.client, transcripts: member.transcripts, paneID: route.paneID, knownSessionID: sessionID,
            cache: conversationCache(for: route.host), drafts: member.drafts, slashDiscovery: ClaudeSlashDiscovery(channel: member.channel),
            haptics: haptics, hostName: route.host == selection ? nil : name(of: route.host),
            // 主機目前只有 macOS／Linux(Windows 的上傳還沒做,ADR-0002)。
            images: ComposerImages(uploader: ImageUploader(channel: member.channel), store: attachmentStore))
    }

    /// 選取中主機上的新增對話(#18)。
    public func newChat() -> NewChatModel {
        let member = member(for: selection)
        let folders = NewChatFolders(channel: member.channel)
        return NewChatModel(launcher: NewChatLauncher(client: member.client, folders: folders), folders: folders)
    }

    /// 新對話開始後：重讀列表，開選取中主機上新 workspace 的 root pane 的聊天(行為規格 F3.2 第 5 步)。
    public func openStartedChat(_ workspace: CreatedWorkspace) async {
        let host = selection
        let list = agentList
        await list.load()
        list.openedChat = ChatRoute(host: host, paneID: workspace.rootPaneID)
    }

    /// 某台主機的對話快取(key 加上主機身分)。
    public func conversationCache(for selection: HostSelection) -> any ConversationCache {
        HostScopedConversationCache(base: conversationCache, scope: selection.storedValue)
    }

    public var rows: [HostRow] {
        _ = iconRevision
        return hosts.map { host in
            HostRow(
                id: host.id, title: host.name,
                subtitle: "\(host.endpoint.username)@\(host.endpoint.host):\(host.endpoint.port)",
                session: host.herdr.session, isSelected: selection == .host(host.id), icon: icon(for: host.id))
        }
    }

    /// 選取中的主機(Demo 時為 `nil`)。
    public var selectedHost: HostConfiguration? {
        guard case .host(let id) = selection else { return nil }
        return hosts.first { $0.id == id }
    }

    /// 主機的顯示名稱(Demo 主機是「Demo」)。
    public func name(of host: HostSelection) -> String {
        switch host {
        case .demo: String(localized: "Demo")
        case .host(let id): hosts.first { $0.id == id }?.name ?? ""
        }
    }

    /// 主機的圖示(只存本機);沒選過是預設圖示。
    public func icon(for id: UUID) -> HostIcon {
        _ = iconRevision
        return hostIcons.icon(for: id) ?? .default
    }

    /// 選取中主機的圖示(主機鈕用)。
    public var selectionIcon: HostIcon { icon(of: selection) }

    /// 替主機選圖示：只存在這支裝置，列表與主機鈕立刻改用它。
    public func setIcon(_ icon: HostIcon, for id: UUID) {
        hostIcons.setIcon(icon, for: id)
        iconRevision += 1
        rebuildMembers()
    }

    /// 從儲存讀主機清單，選回上次選取的主機。
    public func load() {
        do {
            hosts = try sortedHosts()
            loadError = nil
        } catch {
            loadError = String(localized: "Couldn’t read saved hosts on this device. \(error.localizedDescription)")
        }
        select(validSelection(selectionStore.load()))
    }

    /// 選取主機並存起來。只改新聊天開在哪裡、列表排序與主機名標示、Claude 用量與推播設定讀哪台;
    /// 不關閉、不重建任何連線(#39)。
    public func select(_ selection: HostSelection) {
        let host: HostConfiguration?
        switch selection {
        case .demo: host = nil
        case .host(let id):
            guard let found = hosts.first(where: { $0.id == id }) else { return }
            host = found
        }
        self.selection = selection
        selectionStore.save(selection)
        rebuildMembers()
        claudeUsage = ClaudeUsageModel(
            host: ClaudeUsageHost(channel: member(for: selection).channel), hostID: host?.id.uuidString ?? Self.demoID,
            consent: host == nil ? demoConsent : hostConsent)
        codexLauncher = CodexLauncherModel(
            host: CodexLauncherHost(channel: member(for: selection).channel), hostID: host?.id.uuidString ?? Self.demoID,
            consent: host == nil ? demoConsent : hostConsent)
    }

    /// 新增或編輯主機並儲存後：重讀清單並選取它。設定改了，那台主機的連線一律關閉重建。
    public func didSave(_ host: HostConfiguration) {
        changeRecorder?.hostSaved(host.id)
        hosts = (try? sortedHosts()) ?? hosts
        dropChannel(of: host.id)
        members[.host(host.id)] = nil
        select(.host(host.id))
    }

    /// 重新命名：只改名稱，連線與選取不變。
    public func rename(_ id: UUID, to name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw HostManagementError.emptyName }
        guard var host = hosts.first(where: { $0.id == id }) else { throw HostManagementError.notFound }
        host.name = name
        try store.save(host)
        changeRecorder?.hostSaved(id)
        hosts = (try? sortedHosts()) ?? hosts
        rebuildMembers()
    }

    /// 刪除主機(使用者刻意的動作，不另外確認):先刪這台主機的祕密(刪不掉就整個停下，避免留下孤兒祕密，行為規格 §8.1),
    /// 再刪掉此裝置上的設定與 host key pin、清除這台主機的所有主機寫入同意(行為規格 F18)、關閉連線，
    /// 清掉對話快取、釘選／靜音、草稿與圖示。推播配對則不等待地從主機上刪掉並撤銷(行為規格 F14)。
    /// 刪的是選取中主機時，改選第一台剩下的主機(沒有就選 Demo 主機)並存起來。
    public func delete(_ id: UUID) async throws {
        try await remove(id)
        changeRecorder?.hostDeleted(id)
    }

    /// 套用主機同步的結果(別台裝置的新增、修改、刪除)。不通知 `changeRecorder`(不是這支裝置的修改)。
    /// 連線相關的欄位(位址、連線方式、host key 指紋)改了就關掉那台的連線;選取中主機被刪掉時改選第一台。
    public func applySynced(_ outcome: HostSyncOutcome) async throws {
        var reselect = false
        for host in outcome.saves {
            let previous = hosts.first { $0.id == host.id }
            try store.save(host)
            if let previous, previous.endpoint != host.endpoint || previous.connectionMethod != host.connectionMethod
                || previous.authentication != host.authentication || previous.hostKeyPin != host.hostKeyPin {
                dropChannel(of: host.id)
                members[.host(host.id)] = nil
                reselect = reselect || selection == .host(host.id)
            }
        }
        hosts = (try? sortedHosts()) ?? hosts
        for id in outcome.deletions {
            try await remove(id)
        }
        if reselect { select(validSelection(selection)) } else { rebuildMembers() }
    }

    private func remove(_ id: UUID) async throws {
        let removed = hosts.first { $0.id == id }
        // 刪配對要再連一次主機：祕密刪掉前先讀出來，給刪配對用的連線。
        let secret = try? credentials.secrets.secret(for: id)
        try credentials.secrets.setSecret(nil, for: id)
        try store.delete(id)
        if let removed { forgetPush(of: removed, secret: secret) }
        hostConsent.revokeAll(host: id.uuidString)
        hosts.removeAll { $0.id == id }
        let channel = channels.removeValue(forKey: id)
        members[.host(id)] = nil
        preferences.removeAll(for: .host(id))
        hostIcons.setIcon(nil, for: id)
        if selection == .host(id) { select(validSelection(nil)) } else { rebuildMembers() }
        await conversationCache.removeAll(chatKeyPrefix: HostScopedConversationCache.prefix(scope: HostSelection.host(id).storedValue))
        await channel?.disconnect()
    }

    /// 主機的分享連結(QR code 內容)。不含任何祕密。
    public func shareLink(for id: UUID) -> URL? {
        hosts.first { $0.id == id }.map(HostShareLink.url(for:))
    }

    /// 點了推播通知：開配對主機上該 Agent 的聊天。所有主機都在同一個列表，所以不改選取中主機。
    /// 不認得的配對(主機已移除)不動。
    public func open(_ route: PushRoute, pairings: any PushPairingStore) {
        guard let hostID = pairings.host(forKeyHash: route.keyHash), let id = UUID(uuidString: hostID),
              hosts.contains(where: { $0.id == id }) else { return }
        if let paneID = route.paneID { agentList.openedChat = ChatRoute(host: .host(id), paneID: paneID) }
    }

    /// 啟動時：APNs token 換了就向後台重新註冊推播配對。
    public func refreshPushRegistrations() async {
        await pushService?.refreshRegistrations()
    }

    /// 點了推播通知(用 app 的推播紀錄)。
    public func open(_ route: PushRoute) {
        guard let pushService else { return }
        open(route, pairings: pushService.store)
    }

    /// 新增主機(`editing` 為 `nil`)或編輯既有主機的畫面 model。
    public func makeEditor(editing: HostConfiguration? = nil) -> HostEditorModel {
        HostEditorModel(store: store, editing: editing, credentials: credentials, makeChannel: makeChannel)
    }

    /// 從主機分享連結匯入：帶入欄位的新增主機編輯器。連結不合法時丟 `HostShareLinkError`。
    public func makeImportEditor(_ url: URL) throws -> HostEditorModel {
        HostEditorModel(store: store, importing: try HostShareLink.decode(url), credentials: credentials, makeChannel: makeChannel)
    }

    // MARK: - 連線韌性(行為規格 §7.4、§7.5)

    /// 網路路徑改變(狀態 + 可用介面類型組成的字串):丟棄所有主機的連線，下一個指令在新路由上撥號;
    /// 每台主機的列表立刻重連。第一次回報只記錄。被丟棄連線上的 Pane 終端機以「連線中斷」結束(不自動重連)。
    /// - Returns: 丟棄連線並重連的 task(沒有要重設時是 `nil`);呼叫端不必等它，測試用來對齊。
    @discardableResult
    public func networkPathChanged(_ signature: String) -> Task<Void, Never>? {
        defer { networkPath = signature }
        guard let previous = networkPath, previous != signature else { return nil }
        let dropped = Array(channels.values) + [demoChannel]
        let agentList = agentList
        return Task {
            for channel in dropped { await channel.disconnect() }
            agentList.retryNow()
        }
    }

    public func sceneDidEnterBackground(at date: Date) {
        backgroundSince = date
    }

    /// 回到前景：背景超過 60 秒就對已建立的連線跑喚醒探測，死掉的連線在 3 秒內被丟棄;有丟棄就讓每台主機的列表立刻重連。
    public func sceneDidBecomeActive(at date: Date) async {
        guard let since = backgroundSince else { return }
        backgroundSince = nil
        guard date.timeIntervalSince(since) > Double(WakeProbe.backgroundThreshold.components.seconds) else { return }
        let probed = Array(channels.values)
        let allAlive = await withTaskGroup(of: Bool.self) { group in
            for channel in probed { group.addTask { await WakeProbe(channel: channel).run() } }
            var allAlive = true
            for await alive in group { allAlive = allAlive && alive }
            return allAlive
        }
        if !allAlive { agentList.retryNow() }
    }

    private var networkPath: String?
    private var backgroundSince: Date?

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

    private func icon(of host: HostSelection) -> HostIcon {
        if case .host(let id) = host { return icon(for: id) }
        return .default
    }

    /// 列表上的主機：所有已存主機(依名稱);Demo 主機只在沒有已存主機或選了它時。
    /// 已有的成員沿用(連線、列、草稿不重建)。
    private func rebuildMembers() {
        var wanted: [HostSelection] = hosts.map { .host($0.id) }
        if hosts.isEmpty || selection == .demo { wanted.insert(.demo, at: 0) }
        members = members.filter { wanted.contains($0.key) }
        for host in wanted where members[host] == nil { members[host] = makeMember(host) }
        let sources = wanted.compactMap { host in
            members[host].map { member in
                MergedAgentListModel.Source(host: host, name: name(of: host), icon: icon(of: host), list: member.list, actions: member.actions)
            }
        }
        agentList.update(sources: sources, selected: selection)
    }

    /// 某台主機的成員;不在列表上時(例如剛刪除的主機還開著的畫面)暫時建一個不保留的。
    private func member(for host: HostSelection) -> HostMember {
        members[host] ?? makeMember(host)
    }

    private func makeMember(_ host: HostSelection) -> HostMember {
        let configuration: HostConfiguration? = switch host {
        case .demo: nil
        case .host(let id): hosts.first { $0.id == id }
        }
        return HostMember(
            host: host, configuration: configuration, channel: configuration.map(channel(for:)) ?? demoChannel,
            preferences: preferences.store(for: host), push: pushService)
    }

    private func channel(for host: HostConfiguration) -> any HostChannel {
        if let channel = channels[host.id] { return channel }
        let channel = makeChannel(host.endpoint, host.hostKeyPin, credentials.provider(for: host))
        channels[host.id] = channel
        return channel
    }

    /// 推播配對：另開一條不放進 `channels` 的連線刪掉主機上的配對(刪除主機會關閉它原本的連線)。
    private func forgetPush(of host: HostConfiguration, secret: HostSecret?) {
        guard let pushService else { return }
        let provider = credentials.provider(
            method: host.connectionMethod, authentication: host.authentication, hostID: nil, entered: secret)
        pushService.forget(hostID: host.id.uuidString, channel: makeChannel(host.endpoint, host.hostKeyPin, provider), herdr: host.herdr)
    }

    private func dropChannel(of id: UUID) {
        guard let channel = channels.removeValue(forKey: id) else { return }
        Task { await channel.disconnect() }
    }
}

/// 列表上一台主機的連線與 model:各自的通道、herdr client、列表、列操作、草稿與推播開關。
@MainActor
final class HostMember {
    let host: HostSelection
    let channel: any HostChannel
    let client: HerdrClient
    let transcripts: TranscriptReader
    let terminals: PaneTerminalClient
    let list: AgentListModel
    let actions: WorkspaceActionsModel
    /// 輸入列草稿：離開聊天保留、重開 app 不保留(行為規格 F6.2)。每台主機一份(pane id 在每台主機都會重複)。
    let drafts = DraftStore()
    /// 這台主機的推播開關;這台主機的靜音改變時改寫它上面的靜音清單。
    let push: PushModel

    init(
        host: HostSelection, configuration: HostConfiguration?, channel: any HostChannel, preferences: any ChatPreferencesStore,
        push pushService: PushService?
    ) {
        self.host = host
        self.channel = channel
        let herdr = configuration?.herdr ?? HerdrInstallation()
        client = HerdrClient(channel: channel, herdr: herdr)
        transcripts = TranscriptReader(channel: channel)
        terminals = PaneTerminalClient(channel: channel, herdr: herdr)
        let list = AgentListModel(client: client, transcripts: transcripts, host: host)
        self.list = list
        actions = WorkspaceActionsModel(client: client, preferences: preferences, refresh: { await list.load() })
        let push = PushModel(service: pushService, hostID: configuration?.id.uuidString, channel: channel, herdr: herdr) {
            preferences.load().muted
        }
        self.push = push
        actions.mutedChanged = { muted in Task { await push.syncMuted(muted) } }
    }
}
