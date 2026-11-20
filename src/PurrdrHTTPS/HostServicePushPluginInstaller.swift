import Foundation
import PurrdrCore
import Synchronization

/// 推播外掛安裝的主機服務實作(#265):經 HTTPS 連線送 `push.status`／`push.install`／`push.remove`(主機服務 0.6.0 起)。
///
/// 主機服務以本機使用者身分執行 herdr,多裝置規則與 SSH 實作相同。協定沒有改靜音清單的訊息：`updateMuted` 以這次執行
/// 安裝過的配對重送 `push.install`;app 重開後還沒安裝過就丟 `notPaired`。
public struct HostServicePushPluginInstaller: PushPluginInstalling {
    /// 有 `push.*` 訊息的第一個主機服務版本。
    public static let firstVersion = "0.6.0"

    let connection: HTTPSHostConnection
    let deviceID: String
    /// 這次執行安裝過的配對(改靜音清單時重送)。
    private let installedPairing = InstalledPairing()

    public init(connection: HTTPSHostConnection, deviceID: String) {
        self.connection = connection
        self.deviceID = deviceID
    }

    public func status() async throws -> PushPluginStatus {
        try await requirePush()
        let deviceID = deviceID
        let reply = try await request(HostCommandDeadline.standard, failure: PushPluginError.pluginListFailed) {
            .pushStatus(.init(requestId: $0, deviceId: deviceID))
        }
        guard case .pushStatusResult(let result) = reply else { throw HostServiceError.unexpectedResponse }
        return PushPluginStatus(
            user: nil, isPaired: result.paired, pluginInstalled: result.pluginInstalled, otherPairedDevices: result.otherDevices)
    }

    public func install(_ pairing: PushPairingFile) async throws {
        try await requirePush()
        let deviceID = deviceID
        let message = HostServiceProtocol.PushPairing(
            endpoint: pairing.endpoint.absoluteString, key: pairing.key.hex, muted: pairing.writableMuted)
        // 外掛還沒安裝時主機服務會 git clone,期限同 SSH 的下載。
        let reply = try await request(HostCommandDeadline.download, failure: PushPluginError.pluginInstallFailed) {
            .pushInstall(.init(requestId: $0, deviceId: deviceID, pairing: message))
        }
        guard case .pushInstallResult = reply else { throw HostServiceError.unexpectedResponse }
        installedPairing.set(pairing)
    }

    public func remove() async throws {
        try await requirePush()
        let deviceID = deviceID
        let reply = try await request(HostCommandDeadline.standard, failure: PushPluginError.pluginUninstallFailed) {
            .pushRemove(.init(requestId: $0, deviceId: deviceID))
        }
        guard case .pushRemoveResult = reply else { throw HostServiceError.unexpectedResponse }
        installedPairing.set(nil)
    }

    public func updateMuted(_ muted: Set<String>) async throws {
        guard var pairing = installedPairing.get() else { throw PushPluginError.notPaired }
        pairing.muted = muted
        try await install(pairing)
    }

    private func requirePush() async throws {
        let installed = try await connection.hostServiceVersion() ?? ""
        guard HostServiceVersion.isAtLeast(installed, Self.firstVersion) else {
            throw PushPluginError.hostServiceOutdated(installed: installed)
        }
    }

    /// 送出並把 `push_plugin_failed` 換成這個操作的錯誤。
    private func request(
        _ deadline: Duration, failure: @escaping @Sendable (String) -> PushPluginError,
        _ make: @escaping @Sendable (String) -> HostServiceProtocol.ClientMessage
    ) async throws -> HostServiceProtocol.ServerMessage {
        do {
            return try await connection.withDeadline(deadline) { try await connection.send(make) }
        } catch PushPluginError.pluginInstallFailed(let message) {
            throw failure(message)
        }
    }
}

/// 這次執行安裝過的配對。
private final class InstalledPairing: Sendable {
    private let pairing = Mutex<PushPairingFile?>(nil)

    func get() -> PushPairingFile? { pairing.withLock { $0 } }
    func set(_ value: PushPairingFile?) { pairing.withLock { $0 = value } }
}

/// 主機服務版本比較(`1.2.3`;缺的段補 0,看不懂的段當 0)。
enum HostServiceVersion {
    static func isAtLeast(_ installed: String, _ required: String) -> Bool {
        !numbers(installed).lexicographicallyPrecedes(numbers(required))
    }

    static func numbers(_ version: String) -> [Int] {
        let core = version.split(separator: "-", maxSplits: 1).first ?? ""
        let parts = core.split(separator: ".").map { Int($0) ?? 0 }
        return parts + Array(repeating: 0, count: max(0, 3 - parts.count))
    }
}
