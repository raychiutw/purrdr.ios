import Foundation
import PurrdrCore
import PurrdrSSH

/// 第一次連線、還沒有 host key pin 的主機通道(不連網路):一律回報「出示了還沒信任的 host key」,
/// 讓 UI 測試走到「信任這台主機?」的確認畫面(`-uiTestingHostKeyPrompt`,#613)。使用者信任後帶 pin 重建通道,走 Demo 主機。
public struct DemoHostKeyPromptChannel: HostChannel {
    /// 畫面上顯示的假指紋。
    public static let fingerprint = HostKeyFingerprint(stored: "dGVzdC1ob3N0LWtleS1maW5nZXJwcmludC0wMDAwMDA")!

    public init() {}

    public func execute(_ command: String) async throws -> any ExecSession {
        throw SSHConnectionError.hostKeyUnverified(presented: Self.fingerprint)
    }

    public func openPTY(_ request: PTYRequest) async throws -> any PTYSession {
        throw SSHConnectionError.hostKeyUnverified(presented: Self.fingerprint)
    }
}
