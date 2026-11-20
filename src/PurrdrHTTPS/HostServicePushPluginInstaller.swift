import Foundation
import PurrdrCore

/// 推播外掛安裝的主機服務實作(#265):經 HTTPS 連線送 `push.status`／`push.install`／`push.remove`／`push.update_muted`
/// (主機服務 0.6.0 起)。
///
/// 主機服務以本機使用者身分執行 herdr,多裝置規則與 SSH 實作相同。改靜音清單只改主機上的配對檔、不碰外掛，
/// 所以不需要記住密鑰,app 重開後也能改。
public struct HostServicePushPluginInstaller: PushPluginInstalling {
    let connection: HTTPSHostConnection
    let deviceID: PushDeviceID

    public init(connection: HTTPSHostConnection, deviceID: PushDeviceID) {
        self.connection = connection
        self.deviceID = deviceID
    }

    public func status() async throws -> PushPluginStatus {
        try await requirePush()
        let deviceID = deviceID.rawValue
        let reply = try await request(HostCommandDeadline.standard, failure: PushPluginError.pluginListFailed) {
            .pushStatus(.init(requestId: $0, deviceId: deviceID))
        }
        guard case .pushStatusResult(let result) = reply else { throw HostServiceError.unexpectedResponse }
        return PushPluginStatus(
            user: nil, isPaired: result.paired, pluginInstalled: result.pluginInstalled, otherPairedDevices: result.otherDevices)
    }

    public func install(_ pairing: PushPairingFile) async throws {
        try await requirePush()
        let deviceID = deviceID.rawValue
        let message = HostServiceProtocol.PushPairing(
            endpoint: pairing.endpoint.absoluteString, key: pairing.key.hex, muted: pairing.writableMuted)
        // 外掛還沒安裝時主機服務會 git clone,期限同 SSH 的下載。
        let reply = try await request(HostCommandDeadline.download, failure: PushPluginError.pluginInstallFailed) {
            .pushInstall(.init(requestId: $0, deviceId: deviceID, pairing: message))
        }
        guard case .pushInstallResult = reply else { throw HostServiceError.unexpectedResponse }
    }

    public func remove() async throws {
        try await requirePush()
        let deviceID = deviceID.rawValue
        let reply = try await request(HostCommandDeadline.standard, failure: PushPluginError.pluginUninstallFailed) {
            .pushRemove(.init(requestId: $0, deviceId: deviceID))
        }
        guard case .pushRemoveResult = reply else { throw HostServiceError.unexpectedResponse }
    }

    public func updateMuted(_ muted: Set<String>) async throws {
        try await requirePush()
        let deviceID = deviceID.rawValue
        let muted = muted.sorted()
        let reply = try await request(HostCommandDeadline.standard, failure: PushPluginError.pluginListFailed) {
            .pushUpdateMuted(.init(requestId: $0, deviceId: deviceID, muted: muted))
        }
        guard case .pushUpdateMutedResult = reply else { throw HostServiceError.unexpectedResponse }
    }

    private func requirePush() async throws {
        let installed = try await connection.hostServiceVersion()
        guard HostServiceFeature.pushPlugin.isAvailable(onHostServiceVersion: installed) else {
            throw PushPluginError.hostServiceOutdated(installed: installed ?? "")
        }
    }

    /// 送出;主機服務的錯誤直接對應成這個操作的錯誤(`push_plugin_failed` → `failure`、`push_not_paired` → `notPaired`)。
    private func request(
        _ deadline: Duration, failure: @escaping @Sendable (String) -> PushPluginError,
        _ make: @escaping @Sendable (String) -> HostServiceProtocol.ClientMessage
    ) async throws -> HostServiceProtocol.ServerMessage {
        let connection = connection
        let reply = try await connection.withDeadline(deadline) { try await connection.sendKeepingErrors(make) }
        guard case .errorMessage(let error) = reply else { return reply }
        switch error.code {
        case .pushPluginFailed: throw failure(error.message)
        case .pushNotPaired: throw PushPluginError.notPaired
        default: throw HTTPSHostConnection.error(for: error)
        }
    }
}

extension HTTPSHostConnection: PushPluginInstallerProviding {
    public nonisolated func pushPluginInstallers() -> (@Sendable (PushDeviceID) -> any PushPluginInstalling)? {
        let connection = self
        return { deviceID in HostServicePushPluginInstaller(connection: connection, deviceID: deviceID) }
    }
}
