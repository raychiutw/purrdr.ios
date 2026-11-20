import Foundation
import PurrdrCore
import Synchronization

/// 一台假主機的推播外掛與配對，只在記憶體;`installer(deviceID:)` 給每支裝置一個 `PushPluginInstalling`。
///
/// 多裝置規則與 `SSHPushPluginInstaller` 相同：外掛已裝時只新增配對，最後一支裝置移除時才移除 Purrdr 裝的外掛。
public final class FakePushPluginHost: Sendable {
    struct State {
        var pairings: [String: PushPairingFile] = [:]
        var pluginInstalled = false
        var pluginInstalledByPurrdr = false
        var installFailure: String?
        var statusFailure: PushPluginError?
        var updateMutedFailure: (any Error & Sendable)?
        var calls: [String] = []
    }

    public let user: String
    private let state = Mutex(State())

    public init(user: String = "fake-user") {
        self.user = user
    }

    public func installer(deviceID: PushDeviceID) -> any PushPluginInstalling {
        Installer(host: self, deviceID: deviceID.rawValue)
    }

    /// 之後的外掛安裝失敗，丟出 `pluginInstallFailed(message)`;`nil` 恢復成功。
    public func setInstallFailure(_ message: String?) {
        state.withLock { $0.installFailure = message }
    }

    /// 之後的查狀態丟出 `failure`(例如 herdr 沒在跑);`nil` 恢復。
    public func setStatusFailure(_ failure: PushPluginError?) {
        state.withLock { $0.statusFailure = failure }
    }

    /// 使用者自己裝的外掛(Purrdr 不移除)。
    public func installPluginOutsidePurrdr() {
        state.withLock { $0.pluginInstalled = true }
    }

    /// 使用者在主機上手動移除外掛(配對留著)。
    public func uninstallPluginManually() {
        state.withLock {
            $0.pluginInstalled = false
            $0.pluginInstalledByPurrdr = false
        }
    }

    /// 使用者在主機上手動刪掉某支裝置的配對。
    public func removePairingManually(deviceID: PushDeviceID) {
        state.withLock { $0.pairings[deviceID.rawValue] = nil }
    }

    public var pluginInstalled: Bool { state.withLock { $0.pluginInstalled } }

    /// 某支裝置在這台主機上的配對檔。
    public func pairing(deviceID: PushDeviceID) -> PushPairingFile? {
        state.withLock { $0.pairings[deviceID.rawValue] }
    }

    /// 之後的改靜音清單丟出 `failure`;`nil` 恢復。
    public func setUpdateMutedFailure(_ failure: (any Error & Sendable)?) {
        state.withLock { $0.updateMutedFailure = failure }
    }

    /// 依序收到的操作(`status <裝置>`、`install <裝置>`、`remove <裝置>`、`updateMuted <裝置>`)。
    public var calls: [String] { state.withLock { $0.calls } }

    struct Installer: PushPluginInstalling {
        let host: FakePushPluginHost
        let deviceID: String

        func status() async throws -> PushPluginStatus {
            let user = host.user
            return try host.state.withLock { state in
                state.calls.append("status \(deviceID)")
                if let failure = state.statusFailure { throw failure }
                return PushPluginStatus(
                    user: user, isPaired: state.pairings[deviceID] != nil, pluginInstalled: state.pluginInstalled,
                    otherPairedDevices: state.pairings.keys.filter { $0 != deviceID }.count)
            }
        }

        func install(_ pairing: PushPairingFile) async throws {
            try host.state.withLock { state in
                state.calls.append("install \(deviceID)")
                if !state.pluginInstalled {
                    if let message = state.installFailure { throw PushPluginError.pluginInstallFailed(message) }
                    state.pluginInstalled = true
                    state.pluginInstalledByPurrdr = true
                }
                state.pairings[deviceID] = pairing
            }
        }

        func remove() async throws {
            host.state.withLock { state in
                state.calls.append("remove \(deviceID)")
                state.pairings[deviceID] = nil
                if state.pairings.isEmpty && state.pluginInstalledByPurrdr {
                    state.pluginInstalled = false
                    state.pluginInstalledByPurrdr = false
                }
            }
        }

        func updateMuted(_ muted: Set<String>) async throws {
            try host.state.withLock { state in
                state.calls.append("updateMuted \(deviceID)")
                if let failure = state.updateMutedFailure { throw failure }
                guard state.pairings[deviceID] != nil else { throw PushPluginError.notPaired }
                state.pairings[deviceID]?.muted = muted
            }
        }
    }
}
