import Foundation
import PurrdrCore
import PurrdrSSH

/// 一律連不上的主機通道(不連網路)。Demo 的示範主機「Build Box」(#34)與 UI 測試的 `-seedUnreachableHost` 用它，
/// 演出多主機合併列表裡一台連不上的樣子(列表下方「連線中斷」區段)。
/// `hangs` 為 `true` 時連線卡住不回應(直到被取消):演出列表的「連線中」與「仍在連線」(`-seedSlowHost`,#221)。
public struct DemoUnreachableChannel: HostChannel {
    private let hangs: Bool

    public init(hangs: Bool = false) {
        self.hangs = hangs
    }

    public func execute(_ command: String) async throws -> any ExecSession {
        try await failToConnect()
    }

    public func openPTY(_ request: PTYRequest) async throws -> any PTYSession {
        try await failToConnect()
    }

    private func failToConnect() async throws -> Never {
        if hangs {
            try await Task.sleep(for: .seconds(24 * 60 * 60))
        }
        throw SSHConnectionError.timedOut
    }
}
