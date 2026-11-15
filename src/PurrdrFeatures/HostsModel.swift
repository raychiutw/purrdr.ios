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
    /// 讀不到已存主機時的說明。
    public private(set) var loadError: String?

    private let store: any HostStore
    private let demoChannel: any HostChannel
    private let makeChannel: @MainActor (SSHEndpoint, HostKeyFingerprint?) -> any HostChannel
    private var channel: any HostChannel

    public init(
        store: any HostStore, demoChannel: any HostChannel,
        makeChannel: @escaping @MainActor (SSHEndpoint, HostKeyFingerprint?) -> any HostChannel
    ) {
        self.store = store
        self.demoChannel = demoChannel
        self.makeChannel = makeChannel
        channel = demoChannel
        agentList = AgentListModel(client: HerdrClient(channel: demoChannel))
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
            agentList = AgentListModel(client: HerdrClient(channel: channel, herdr: host.herdr))
        } else {
            channel = demoChannel
            agentList = AgentListModel(client: HerdrClient(channel: demoChannel))
        }
        self.selection = selection
        Task { await previous.disconnect() }
    }

    /// 新增或編輯主機並儲存後：重讀清單並選取它(設定改了，連線一律重建)。
    public func didSave(_ host: HostConfiguration) {
        hosts = (try? store.loadHosts())?.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } ?? hosts
        select(.host(host.id))
    }

    /// 新增主機(`editing` 為 `nil`)或編輯既有主機的畫面 model。
    public func makeEditor(editing: HostConfiguration? = nil) -> HostEditorModel {
        HostEditorModel(store: store, editing: editing, makeChannel: makeChannel)
    }
}
