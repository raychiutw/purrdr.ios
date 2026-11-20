import Foundation
import PurrdrCore

/// 從 app 管理主機服務(#290):`host_service.status`／`update`／`set_auto_update`。主機服務 0.7.0 起才有，
/// 更舊的不送出、丟 `hostServiceUpdateRequired`。
extension HTTPSHostConnection: HostServiceManaging {
    public func hostServiceUpdateStatus() async throws -> HostServiceUpdateStatus {
        let reply = try await sendManagement { .hostServiceStatus(.init(requestId: $0)) }
        guard case .hostServiceStatusResult(let result) = reply else { throw HostServiceError.unexpectedResponse }
        return HostServiceUpdateStatus(
            installedVersion: result.installedVersion, latestVersion: result.latestVersion, latestError: result.latestError,
            updateAvailable: result.updateAvailable, autoUpdate: result.autoUpdate,
            lastUpdate: result.lastUpdate.map { HostServiceLastUpdate(checkedAtText: $0.checkedAt, result: $0.result) },
            rolledBack: result.rolledBack)
    }

    public func updateHostService() async throws -> HostServiceUpdateStart {
        let reply = try await sendManagement { .hostServiceUpdate(.init(requestId: $0)) }
        guard case .hostServiceUpdateResult(let result) = reply else { throw HostServiceError.unexpectedResponse }
        switch result.outcome {
        case .started: return .started(from: result.fromVersion, to: result.toVersion)
        case .upToDate: return .upToDate(version: result.toVersion)
        }
    }

    public func setHostServiceAutoUpdate(_ enabled: Bool) async throws -> Bool {
        let reply = try await sendManagement { .hostServiceSetAutoUpdate(.init(requestId: $0, enabled: enabled)) }
        guard case .hostServiceSetAutoUpdateResult(let result) = reply else { throw HostServiceError.unexpectedResponse }
        return result.autoUpdate
    }

    public func reconnectForHostServiceVersion() async throws -> String? {
        await disconnect()
        return try await withDeadline(HostCommandDeadline.standard) { try await self.hostServiceVersion() }
    }

    private func sendManagement(
        _ make: @escaping @Sendable (String) -> HostServiceProtocol.ClientMessage
    ) async throws -> HostServiceProtocol.ServerMessage {
        try await requireHostService(.hostServiceManagement)
        return try await withDeadline(HostCommandDeadline.standard) { try await self.send(make) }
    }
}
