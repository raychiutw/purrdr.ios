import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 主機 tab(#392、DESIGN.md「主機 tab」):目前選取那台主機的總頁。
///
/// 頂列中間是主機切換選單(多台主機的管理入口,不另做清單頁)、右上新增主機與帳號。
/// 總頁的連線狀態、用量、主機服務、通知、登入 Shell、分享、主機設定、編輯與移除都在這一頁;
/// 新增、編輯、分享與各子頁在同一個 `NavigationStack` 內 push,不疊 sheet。
struct HostsTab: View {
    let hosts: HostsModel
    let member: MemberModel
    /// 通知要有 Purrdr Plus(#405):沒有時通知列鎖定、點了開付費牆。
    let plus: SubscriptionModel?
    /// 等著匯入的主機分享連結(深層連結帶進來的);開啟後清掉。
    @Binding var importURL: URL?
    /// 等著開編輯頁的主機(點了主機服務通知);開啟後清掉。
    @Binding var editHostID: UUID?
    /// 要直接開新增主機引導(Agent 列表空狀態的「新增主機」);開啟後清掉。
    @Binding var addHost: Bool
    let openAccount: () -> Void
    let openAddHost: () -> Void
    let openPlus: () -> Void
    /// 點「範例主機」後回聊天 tab(範例的對話在那裡)。
    let didEnterDemo: () -> Void

    @State private var flow = HostListFlow()
    @State private var statusCache = HostStatusCache()
    @State private var actionError: DisplayedError?
    @State private var confirmingRemoveDemo = false

    /// 存好或完成引導後回到總頁。
    private func finish() {
        flow.path = []
    }

    var body: some View {
        NavigationStack(path: $flow.path) {
            content
                // 共用頂列(#500、#616):大標題「主機」,右側 [電腦圖示｜＋] 與頭像。電腦圖示選單選看哪一台主機(與檔案 tab 同一個選單,
                // 最下面「新增主機…」);選到需要重新確認的主機(#572)直接開編輯頁。沒有搜尋,往下滑收成置中小標題。
                .topBarPage(topBarContent)
                .navigationDestination(for: HostRoute.self) { destination($0) }
        }
        .onAppear {
            // 已配對裝置「這支裝置」那列:確認在那一列上問過了(#625),確認後回總頁移除(#291)。
            statusCache.removeHost = { id, name in
                flow.path.removeAll()
                confirmDeletion(HostDeletionRequest(id: id, name: name))
            }
        }
        .onAppear(perform: openPendingImport)
        .onChange(of: importURL) { openPendingImport() }
        .onAppear(perform: openPendingEditor)
        .onChange(of: editHostID) { openPendingEditor() }
        .onAppear(perform: openPendingAdd)
        .onChange(of: addHost) { openPendingAdd() }
    }

    private var topBarContent: TopBarContent {
        let picker = hosts.screens.selectedHostPicker()
        return TopBarContent(
            tab: .hosts, title: "Hosts",
            hostScope: .selected(hostName: hosts.overview?.name),
            hostMenu: AnyView(
                HostSelectionMenu(
                    model: picker, addHost: { flow.path.append(.add) },
                    reconfirm: { flow.openEditor(of: $0) })),
            hostIdentifier: "hosts.host",
            plus: AnyView(TopBarPlusButton(title: "Add Host", identifier: "hosts.add") { flow.path.append(.add) }),
            account: AnyView(TopBarAccountButton(member: member, action: openAccount)))
    }

    @ViewBuilder
    private var content: some View {
        if let overview = hosts.overview {
            HostOverviewView(
                hosts: hosts, overview: overview, plus: plus, openPlus: openPlus, statusCache: statusCache, actionError: actionError,
                flow: flow, confirmRemoval: confirmDeletion,
                confirmingRemoveDemo: $confirmingRemoveDemo, confirmRemoveDemo: { hosts.removeDemo() }, openAddHost: { flow.path.append(.add) },
                openRoute: { flow.path.append($0) })
                // 換主機就重新建立(用量區與主機服務各自的 model 屬於那台主機)。
                .id(overview.host)
        } else {
            TabUnavailableView(
                title: "No Hosts", systemImage: "desktopcomputer",
                message: "Add a host to see its status, usage, and settings here.", identifier: "hosts.noHost")
        }
    }

    // MARK: - 導覽目的地

    private func destination(_ route: HostRoute) -> some View {
        Group {
            switch route {
            case .add:
                AddHostGuideScreen(make: hosts.screens.makeAddHostGuide) { _ in
                    finish()  // 主機在存好時已登記(onAdded)
                } onAdded: { hosts.didSave($0) } hostPush: { id in
                    hosts.hostPushes.first { $0.host == .host(id) }
                } onTryDemo: {
                    // 範例主機入口(#394):啟用後回到總頁,tab 切到聊天。
                    hosts.enterDemo()
                    flow.path = []
                    didEnterDemo()
                }
            case .importGuide(let url):
                AddHostGuideScreen(make: { (try? hosts.screens.makeImportGuide(url)) ?? hosts.screens.makeAddHostGuide() }) { _ in
                    finish()
                } onAdded: { hosts.didSave($0) } hostPush: { id in
                    hosts.hostPushes.first { $0.host == .host(id) }
                }
            case .pairGuide(let id):
                AddHostGuideScreen(
                    make: {
                        hosts.hosts.first { $0.id == id }.flatMap { try? hosts.screens.makePairingGuide(for: $0) } ?? hosts.screens.makeAddHostGuide()
                    }
                ) { _ in
                    finish()
                } onAdded: { hosts.didSave($0) } hostPush: { id in
                    hosts.hostPushes.first { $0.host == .host(id) }
                }
            case .edit:
                // 編輯主機:名稱、圖示、連線方式與測試連線(主機主題等設定在「這台主機的設定」)。
                HostEditorView(
                    model: hosts.screens.makeEditor(editing: route.hostID.flatMap { id in hosts.hosts.first { $0.id == id } })
                ) { host in
                    hosts.didSave(host)
                    finish()
                } onIconSaved: {
                    finish()
                }
                .appPageContentWidth()
            case .hostServiceUpdate(let id):
                if let row = hosts.rows.first(where: { $0.id == id }), let version = row.hostServiceUpdate,
                    let commands = row.hostServiceUpdateCommands
                {
                    HostServiceUpdateView(hostName: row.title, version: version, commands: commands) {
                        hosts.dismissHostServiceUpdate(for: id)
                        flow.path.removeLast()
                    }
                    .appPageContentWidth()
                }
            case .share(let id):
                if let host = hosts.hosts.first(where: { $0.id == id }), let link = hosts.shareLink(for: id) {
                    HostShareView(name: host.name, link: link)
                        .appPageContentWidth()
                }
            case .notifications:
                HostNotificationsPage(
                    hosts: hosts, host: hosts.selection, signedIn: signedIn, openAccount: openAccount, openPlus: openPlus,
                    pair: { flow.path.append(.pairGuide($0)) })
                    .appPageContentWidth()
            case .hostSettings(let id):
                if let settings = hosts.member(for: .host(id)).settings() {
                    HostSettingsPage(
                        hosts: hosts, hostID: id, settings: settings, isReadOnly: hosts.overview?.status == .readOnly)
                        .appPageContentWidth()
                }
            case .agents(let id):
                if let model = hosts.member(for: .host(id)).agentSettings() {
                    HostAgentSettingsPage(hosts: hosts, hostID: id, model: model)
                        .appPageContentWidth()
                }
            case .pairedDevices(let id):
                if let devices = statusCache.models(for: id, hosts: hosts)?.pairedDevices {
                    HostPairedDevicesPage(model: devices)
                        .appPageContentWidth()
                }
            case .loginShell:
                LoginShellTool(hosts: hosts)
            case .importFailed:
                ContentUnavailableView(
                    "Can’t Add This Host", systemImage: "qrcode",
                    description: Text("This link isn’t a Purrdr host, or it was made by a newer version of Purrdr."))
                    .accessibilityIdentifier("hosts.importFailed")
            }
        }
        // 主機編輯器的「測試連線」也可能遇到 check mode。
        .tailscaleCheckPrompt(hosts.tailscaleCheck)
    }

    private var signedIn: Bool {
        if case .signedIn = member.phase { return true }
        return false
    }

    // MARK: - 移除

    private func confirmDeletion(_ request: HostDeletionRequest) {
        Task {
            do {
                try await flow.confirmDeletion(of: request) { try await hosts.delete($0) }
                actionError = nil
            } catch {
                actionError = DisplayedError(
                    String(localized: "Couldn’t remove this host from this device. \(error.localizedDescription)"), error: error)
            }
        }
    }

    // MARK: - 從外部開啟

    private func openPendingImport() {
        guard let url = importURL else { return }
        importURL = nil
        flow.path = [(try? hosts.screens.makeImportGuide(url)) != nil ? .importGuide(url) : .importFailed]
    }

    private func openPendingAdd() {
        guard addHost else { return }
        addHost = false
        flow.path = [.add]
    }

    private func openPendingEditor() {
        guard let id = editHostID else { return }
        editHostID = nil
        flow.openEditor(of: id)
    }
}

/// 進畫面才建立登入 Shell 的主機挑選鈕(換主機掛斷舊 shell、在新主機開新的)。
private struct LoginShellTool: View {
    let hosts: HostsModel
    @State private var picker: HostPickerModel

    init(hosts: HostsModel) {
        self.hosts = hosts
        _picker = State(wrappedValue: hosts.screens.hostPicker(for: .loginShell))
    }

    var body: some View {
        LoginShellScreen(hosts: hosts, picker: picker)
            .hidesTabBarWhenCompact()
    }
}

/// 每台主機一份的主機服務與已配對裝置 model(總頁與「已配對裝置」子頁共用同一份,下拉重新整理才讀得到同樣的資料)。
@MainActor
final class HostStatusCache {
    private var cache: [UUID: HostStatusModels] = [:]
    /// 開移除主機的確認(主機 id 與名稱);由主機 tab 設定。
    var removeHost: (UUID, String) -> Void = { _, _ in }

    /// 已配對 HTTPS 主機才有。
    func models(for id: UUID, hosts: HostsModel) -> HostStatusModels? {
        if let existing = cache[id] { return existing }
        guard let connection = hosts.hostStatusConnection(for: id), let host = hosts.hosts.first(where: { $0.id == id }) else { return nil }
        let name = host.name
        let models = HostStatusModels(connection: connection, hostName: name, removeHost: { [weak self] in self?.removeHost(id, name) })
        cache[id] = models
        return models
    }
}
