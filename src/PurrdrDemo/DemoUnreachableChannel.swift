import Foundation
import PurrdrCore
import PurrdrSSH

/// 一律連不上的主機通道(不連網路)。Demo 的示範主機「Build Box」(#34)與 UI 測試的 `-seedUnreachableHost` 用它，
/// 演出多主機合併列表裡一台連不上的樣子(列表下方「連線中斷」區段)。
public struct DemoUnreachableChannel: HostChannel {
    public init() {}

    public func execute(_ command: String) async throws -> any ExecSession {
        throw SSHConnectionError.timedOut
    }

    public func openPTY(_ request: PTYRequest) async throws -> any PTYSession {
        throw SSHConnectionError.timedOut
    }
}
