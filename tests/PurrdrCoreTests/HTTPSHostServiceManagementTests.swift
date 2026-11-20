import Foundation
import PurrdrCore
import PurrdrHTTPS
import Testing

/// 從 app 管理主機服務(#290):經真正的 WebSocket 連假的主機服務，回應來自協定範例。
@Suite("HTTPS 主機：管理主機服務")
struct HTTPSHostServiceManagementTests {
    private static func connection(to service: FakeHostService, token: String = "token-ok") -> HTTPSHostConnection {
        HTTPSHostConnection(address: service.address, deviceToken: { token }, appVersion: "9.9.9")
    }

    private static func service(_ change: @escaping @Sendable (inout FakeHostService.Settings) -> Void = { _ in }) async throws
        -> FakeHostService
    {
        let service = try await FakeHostService.start(.init(hostServiceVersion: "0.7.0"))
        service.update(change)
        return service
    }

    @Test("狀態：送 host_service.status,讀出版本、最新版本、自動更新、上次結果與退回的版本")
    func status() async throws {
        let service = try await Self.service()
        defer { Task { await service.stop() } }

        let status = try await Self.connection(to: service).hostServiceUpdateStatus()

        #expect(service.messages(ofType: "host_service.status").count == 1)
        #expect(status.installedVersion == "0.6.0")
        #expect(status.latestVersion == "0.7.0")
        #expect(status.updateAvailable)
        #expect(status.autoUpdate)
        #expect(status.rolledBack == "0.7.0")
        #expect(status.lastUpdate?.checkedAtText == "2026-11-20T08:00:00Z")
        #expect(status.lastUpdate?.checkedAt == Date(timeIntervalSince1970: 1_795_161_600))
        #expect(status.lastUpdate?.result.hasPrefix("update failed:") == true)
    }

    @Test("取不到最新版本：沒有 latestVersion,帶原因")
    func statusOffline() async throws {
        let service = try await Self.service { $0.hostServiceStatusExample = "server.host-service-status-result.offline.json" }
        defer { Task { await service.stop() } }

        let status = try await Self.connection(to: service).hostServiceUpdateStatus()

        #expect(status.latestVersion == nil)
        #expect(status.latestError?.contains("connection refused") == true)
        #expect(status.updateAvailable == false)
    }

    @Test("立即更新：送 host_service.update,回報從哪版更新到哪版")
    func updateStarted() async throws {
        let service = try await Self.service()
        defer { Task { await service.stop() } }

        let start = try await Self.connection(to: service).updateHostService()

        #expect(service.messages(ofType: "host_service.update").count == 1)
        #expect(start == .started(from: "0.6.0", to: "0.7.0"))
    }

    @Test("已是最新：不更新")
    func updateUpToDate() async throws {
        let service = try await Self.service { $0.hostServiceUpdateExample = "server.host-service-update-result.up-to-date.json" }
        defer { Task { await service.stop() } }

        #expect(try await Self.connection(to: service).updateHostService() == .upToDate(version: "0.7.0"))
    }

    @Test(
        "主機服務的錯誤碼對應到專屬錯誤",
        arguments: [
            ("update_in_progress", HostServiceManagementError.updateInProgress),
            ("host_service_not_installed", .notInstalledCopy),
            ("update_failed", .updateFailed("failed")),
        ])
    func updateErrors(code: String, expected: HostServiceManagementError) async throws {
        let service = try await Self.service { $0.hostServiceErrorCode = code }
        defer { Task { await service.stop() } }

        await #expect(throws: expected) { try await Self.connection(to: service).updateHostService() }
    }

    @Test("開關自動更新：送 host_service.set_auto_update,回傳改完的開關")
    func setAutoUpdate() async throws {
        let service = try await Self.service()
        defer { Task { await service.stop() } }

        let enabled = try await Self.connection(to: service).setHostServiceAutoUpdate(false)

        #expect(service.messages(ofType: "host_service.set_auto_update").first?["enabled"] as? Bool == false)
        #expect(enabled == false)
    }

    @Test("唯讀裝置：更新與自動更新被拒，錯誤種類是 readOnlyDevice;狀態仍可看")
    func readOnlyDevice() async throws {
        let service = try await Self.service { $0.readOnlyTokens = ["token-ok"] }
        defer { Task { await service.stop() } }
        let connection = Self.connection(to: service)

        await #expect(throws: HostServiceError.readOnlyDevice) { try await connection.updateHostService() }
        await #expect(throws: HostServiceError.readOnlyDevice) { try await connection.setHostServiceAutoUpdate(true) }
        _ = try await connection.hostServiceUpdateStatus()
    }

    @Test("主機服務 0.7.0 以前沒有這些訊息：不送出，回「需要更新主機服務」")
    func olderHostService() async throws {
        let service = try await FakeHostService.start(.init(hostServiceVersion: "0.6.0"))
        defer { Task { await service.stop() } }

        await #expect(throws: HostServiceError.hostServiceUpdateRequired(.hostServiceManagement, installedVersion: "0.6.0")) {
            try await Self.connection(to: service).hostServiceUpdateStatus()
        }
        #expect(service.messages(ofType: "host_service.status").isEmpty)
    }

    @Test("重新連線：丟掉舊連線、重新握手，回報新的 welcome 版本")
    func reconnectReportsNewVersion() async throws {
        let service = try await Self.service()
        defer { Task { await service.stop() } }
        let connection = Self.connection(to: service)
        _ = try await connection.hostServiceVersion()

        service.update { $0.hostServiceVersion = "0.7.1" }
        let version = try await connection.reconnectForHostServiceVersion()

        #expect(version == "0.7.1")
        #expect(service.log.connections == 2)
    }
}
