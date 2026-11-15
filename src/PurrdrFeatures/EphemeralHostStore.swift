import Foundation
import PurrdrCore

/// 只存在記憶體的主機儲存。UI 測試用(`-uiTesting` 不碰 Keychain、不連網路)。
@MainActor
public final class EphemeralHostStore: HostStore {
    private var hosts: [HostConfiguration]

    public init(hosts: [HostConfiguration] = []) {
        self.hosts = hosts
    }

    public func loadHosts() throws -> [HostConfiguration] { hosts }

    public func save(_ host: HostConfiguration) throws {
        hosts.removeAll { $0.id == host.id }
        hosts.append(host)
    }

    public func delete(_ id: UUID) throws { hosts.removeAll { $0.id == id } }
}
