import PurrdrCore
import SwiftUI

/// app 的第一個畫面：選取中主機的 Agent 列表，工具列的主機鈕開主機清單。
public struct RootView: View {
    let hosts: HostsModel
    @State private var showingHosts = false

    public init(hosts: HostsModel) {
        self.hosts = hosts
    }

    public var body: some View {
        AgentListView(model: hosts.agentList) { showingHosts = true }
            // 換主機時整個列表重建(載入狀態、事件串流、搜尋字都重置，行為規格 F1.3)。
            .id(hosts.selection)
            .sheet(isPresented: $showingHosts) {
                HostListView(model: hosts)
            }
    }
}

/// 只存在記憶體的主機儲存。UI 測試用(`-uiTesting` 不碰 Keychain、不連網路)。
@MainActor
public final class EphemeralHostStore: HostStore {
    private var hosts: [HostConfiguration] = []

    public init() {}

    public func loadHosts() throws -> [HostConfiguration] { hosts }

    public func save(_ host: HostConfiguration) throws {
        hosts.removeAll { $0.id == host.id }
        hosts.append(host)
    }

    public func delete(_ id: UUID) throws { hosts.removeAll { $0.id == id } }
}
