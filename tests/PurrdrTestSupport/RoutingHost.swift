import Foundation
import PurrdrCore
import PurrdrSSH

// 用 `Process` 在本機跑 shell,只在 macOS(`swift test`)提供。
#if os(macOS)

/// 把 `herdr remote-api-bridge` 交給假主機(回放錄製的 herdr 回應)、其他指令交給 `LocalShellHost`
/// (在本機對真實檔案跑對話紀錄腳本)的主機通道。畫面 model 的測試用它，一次走完 herdr 與對話紀錄兩條路。
public actor RoutingHost: HostChannel {
    public let bridge: FakeHost
    public let shell: LocalShellHost
    /// 交給 shell 的指令，依執行順序。
    public private(set) var shellCommands: [String] = []

    public init(bridge: FakeHost = FakeHost(), shell: LocalShellHost) {
        self.bridge = bridge
        self.shell = shell
    }

    public func execute(_ command: String) async throws -> any ExecSession {
        if command.hasSuffix(" remote-api-bridge") {
            return try await bridge.execute(command)
        }
        shellCommands.append(command)
        return try await shell.execute(command)
    }

    public func openPTY(_ request: PTYRequest) async throws -> any PTYSession {
        try await bridge.openPTY(request)
    }
}

#endif
