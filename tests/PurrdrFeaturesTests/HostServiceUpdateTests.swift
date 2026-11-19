import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

@MainActor
@Suite("主機服務的更新提示(#198)")
struct HostServiceUpdateTests {
    /// 三台已配對的 HTTPS 主機(名稱決定排序，也就是連線建立的順序)與一台 SSH 主機。
    static func hosts() -> (store: MemoryHostStore, tokens: InMemoryDeviceTokenStore) {
        let store = MemoryHostStore()
        store.hosts = [
            HostConfiguration(name: "A Older", hostService: HostServiceAddress("a.tail1234.ts.net")!),
            HostConfiguration(name: "B Same", hostService: HostServiceAddress("b.tail1234.ts.net")!),
            HostConfiguration(name: "C Newer", hostService: HostServiceAddress("c.tail1234.ts.net")!),
            HostConfiguration(name: "D SSH", endpoint: SSHEndpoint(host: "studio-mac", username: "ray")),
        ]
        let tokens = InMemoryDeviceTokenStore(
            tokens: Dictionary(uniqueKeysWithValues: store.hosts.filter(\.connectionMethod.usesHostService).map { ($0.id, "token-saved") }))
        return (store, tokens)
    }

    static func connections(reporting versions: [String]) async -> HostServiceConnections {
        let connections = HostServiceConnections()
        for version in versions {
            let connection = FakeHostConnection()
            await connection.setHostServiceVersion(version)
            connections.connections.append(connection)
        }
        return connections
    }

    static func model(
        latest: String, store: MemoryHostStore, tokens: InMemoryDeviceTokenStore, connections: HostServiceConnections,
        dismissals: any HostServiceUpdateStore
    ) -> HostsModel {
        HostsModel(
            store: store, demoChannel: FakeHost(), hostService: connections.access(tokens: tokens),
            hostServiceUpdates: HostServiceUpdates(latestVersion: latest, store: dismissals), makeChannel: ChannelFactory().make)
    }

    static func updates(_ model: HostsModel) -> [String: String] {
        Dictionary(uniqueKeysWithValues: model.rows.compactMap { row in row.hostServiceUpdate.map { (row.title, $0) } })
    }

    @Test("主機服務比 app 已知的最新版舊才標示可更新(依版本數字比較);同版、較新與 SSH 主機不標示")
    func rowsShowOutdatedHostService() async {
        let (store, tokens) = Self.hosts()
        let connections = await Self.connections(reporting: ["0.9.0", "0.10.0", "0.11.0"])
        let model = Self.model(
            latest: "0.10.0", store: store, tokens: tokens, connections: connections, dismissals: InMemoryHostServiceUpdateStore())
        model.load()
        #expect(Self.updates(model).isEmpty)

        await model.checkHostServiceVersions()

        #expect(Self.updates(model) == ["A Older": "0.10.0"])
    }

    @Test("關閉提示後同一個新版本不再出現(存在這支裝置);app 知道更新的版本時再提示")
    func dismissedUpdateStaysHiddenUntilNewerRelease() async throws {
        let (store, tokens) = Self.hosts()
        let dismissals = InMemoryHostServiceUpdateStore()
        let model = Self.model(
            latest: "0.10.0", store: store, tokens: tokens,
            connections: await Self.connections(reporting: ["0.9.0", "0.10.0", "0.11.0"]), dismissals: dismissals)
        model.load()
        await model.checkHostServiceVersions()
        let older = try #require(model.rows.first { $0.title == "A Older" })

        model.dismissHostServiceUpdate(for: older.id)

        #expect(Self.updates(model).isEmpty)
        let reopened = Self.model(
            latest: "0.10.0", store: store, tokens: tokens,
            connections: await Self.connections(reporting: ["0.9.0", "0.10.0", "0.11.0"]), dismissals: dismissals)
        reopened.load()
        await reopened.checkHostServiceVersions()
        #expect(Self.updates(reopened).isEmpty)
        let newerRelease = Self.model(
            latest: "0.12.0", store: store, tokens: tokens,
            connections: await Self.connections(reporting: ["0.9.0", "0.10.0", "0.11.0"]), dismissals: dismissals)
        newerRelease.load()
        await newerRelease.checkHostServiceVersions()
        #expect(Self.updates(newerRelease) == ["A Older": "0.12.0", "B Same": "0.12.0", "C Newer": "0.12.0"])
    }

    @Test("app 已知的最新主機服務版本與 vendor/purrdr-host/VERSION 同步來的主機服務版本一致(發行主機服務時一起遞增)")
    func latestVersionMatchesSyncedHostServiceVersion() throws {
        let versionFile = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "vendor/purrdr-host/VERSION")
        let contents = try String(contentsOf: versionFile, encoding: .utf8)
        let prefix = "host_service_version="
        let line = try #require(contents.split(separator: "\n").first { $0.hasPrefix(prefix) })

        #expect(HostServiceUpdates.latestKnownVersion == String(line.dropFirst(prefix.count)))
    }

    @Test("一行安裝指令從主機端 repo raychiutw/purrdr-host 的最新 Release 下載")
    func installCommandsDownloadFromPurrdrHostReleases() {
        let base = "https://github.com/raychiutw/purrdr-host/releases/latest/download/"
        #expect(HostServiceUpdates.posixInstallCommand == "curl -fsSL \(base)install.sh | sh")
        #expect(HostServiceUpdates.windowsInstallCommand == "irm \(base)install.ps1 | iex")
    }
}
