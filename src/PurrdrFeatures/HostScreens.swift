import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrHTTPS
import PurrdrSSH

/// 跨主機的畫面 model 工廠(#564):主機挑選、數據用量、方案用量與新增／編輯主機。
/// 作用在單一主機的畫面 model 在那台主機的成員上(`HostMember+Screens.swift`);這裡的畫面要列出所有主機,或還沒有成員(新增主機)。
/// 清單狀態從 `HostsModel` 讀,不寫。
@MainActor
public struct HostScreens {
    let hosts: HostsModel

    /// 數據用量頁的 model(#354):主機選單是 Demo 主機加上所有已存主機,預設看目前主機(#334);在這裡改主機只改這個畫面的選取,不動聊天列表的目前主機(切換規則,#390)。
    public func dataUsage() -> DataUsageModel {
        DataUsageModel(
            meter: hosts.trafficMeter ?? TrafficMeter(store: InMemoryTrafficStore()), hosts: hosts.hostOptions { _ in true },
            currentHost: hosts.agentList.currentHost)
    }

    /// 方案用量畫面的 model(#177):打開畫面時建立。主機選單是 Demo 主機加上所有已存主機，預設選取中主機。
    /// `host`、`agent` 有值時直接選那台與那個 Agent(用量區的「啟用用量顯示」導到這裡的同意流程)。
    public func planUsage(host: HostSelection? = nil, agent: PlanUsageAgent? = nil) -> PlanUsageModel {
        let hosts = hosts
        return PlanUsageModel(
            hosts: hosts.hostOptions { _ in true }, fallback: hosts.selection, store: hosts.planUsageSelection,
            currentHost: host ?? hosts.agentList.currentHost, initialAgent: agent,
            enabledAgents: { [weak hosts] in hosts?.enabledAgents(on: $0) ?? Set(HostAgentSettings.configurable) }
        ) { [weak hosts] host, agent in
            hosts?.planUsageSource(host, agent)
        }
    }

    /// 登入 Shell、檔案的主機挑選鈕(#245):只列支援的主機(HTTPS 主機沒有，ADR-0010),預設上次選的電腦或選取中主機。
    public func hostPicker(for scope: HostPickerScope) -> HostPickerModel {
        let options = hosts.hostOptions { $0.supportsLoginShell }
        return .remembering(scope, options: options, fallback: hosts.selection, store: hosts.hostPickerStore)
    }

    /// 檔案與主機 tab 頂列的主機選單(#390):只改選取中主機、不列「所有主機」,在那裡換主機不動聊天列表的篩選。
    /// 範例主機啟用前不列入。
    public func selectedHostPicker() -> HostPickerModel {
        HostPickerModel(options: hosts.hostOptions { _ in true }, preferred: [hosts.selection]) { [weak hosts] in
            hosts?.select($0)
        }
    }

    /// 新增聊天的主機挑選鈕(#245):所有主機;預設聊天列表目前篩選的主機(#244),所有主機時用選取中主機。
    public func newChatHostPicker(preferring host: HostSelection? = nil) -> HostPickerModel {
        .newChat(options: hosts.hostOptions { _ in true }, currentHost: host ?? hosts.agentList.currentHost, selection: hosts.selection)
    }

    /// 新增主機(`editing` 為 `nil`)或編輯既有主機的畫面 model。`method`:新增時預選的連線方式。
    public func makeEditor(editing: HostConfiguration? = nil, method: HostConfiguration.ConnectionMethod? = nil) -> HostEditorModel {
        let hosts = hosts
        let editor = HostEditorModel(
            store: hosts.store, editing: editing, credentials: hosts.credentials, hostService: hosts.hostService,
            icon: editing.map { hosts.icon(for: $0.id) } ?? .default, saveIcon: { [weak hosts] in hosts?.setIcon($0, for: $1) },
            renameHost: { [weak hosts] id, name in try hosts?.rename(id, to: name) }, makeChannel: hosts.makeChannel)
        if editing == nil, let method { editor.connectionMethod = method }
        editor.attachTraffic(hosts.trafficProvider)
        return editor
    }

    /// 所有新增入口(歡迎頁、主機清單「＋」、「⋯」選單)開的新增主機引導(#341)。
    public func makeAddHostGuide() -> AddHostGuideModel {
        let guide = AddHostGuideModel(
            store: hosts.store, credentials: hosts.credentials, hostService: hosts.hostService, isSignedIn: hosts.guideSignedInCheck,
            makeChannel: hosts.makeChannel)
        guide.attachTraffic(hosts.trafficProvider)
        return guide
    }

    /// 匯入連結(主機分享連結、配對 QR code)開的引導,資料已齊時直接到測試連線(#344);引導接不了(原生 SSH、壞連結)時丟錯。
    public func makeImportGuide(_ url: URL) throws -> AddHostGuideModel {
        let guide = try AddHostGuideModel(
            store: hosts.store, credentials: hosts.credentials, hostService: hosts.hostService, isSignedIn: hosts.guideSignedInCheck,
            makeChannel: hosts.makeChannel, shortcut: .importLink(url))
        guide.attachTraffic(hosts.trafficProvider)
        return guide
    }

    /// 同步來、這支裝置還沒配對的 HTTPS 主機:直接到配對步驟(#344)。
    public func makePairingGuide(for host: HostConfiguration) throws -> AddHostGuideModel {
        let guide = try AddHostGuideModel(
            store: hosts.store, credentials: hosts.credentials, hostService: hosts.hostService, isSignedIn: hosts.guideSignedInCheck,
            makeChannel: hosts.makeChannel, shortcut: .needsPairing(host))
        guide.attachTraffic(hosts.trafficProvider)
        return guide
    }

    /// 從主機分享連結或主機配對指令的 QR code(`purrdr://pair?…`)新增主機：帶入欄位的編輯器。
    /// 連結不合法時丟 `HostShareLinkError` 或 `HostServicePairingLinkError`。
    public func makeImportEditor(_ url: URL) throws -> HostEditorModel {
        let saveIcon: @MainActor (HostIcon, UUID) -> Void = { [weak hosts] in hosts?.setIcon($0, for: $1) }
        if HostServicePairingLink.isPairingLink(url) {
            return HostEditorModel(
                store: hosts.store, pairing: try HostServicePairingLink(url: url), credentials: hosts.credentials,
                hostService: hosts.hostService, saveIcon: saveIcon, makeChannel: hosts.makeChannel)
        }
        return HostEditorModel(
            store: hosts.store, importing: try HostShareLink.decode(url), credentials: hosts.credentials, hostService: hosts.hostService,
            saveIcon: saveIcon, makeChannel: hosts.makeChannel)
    }
}
