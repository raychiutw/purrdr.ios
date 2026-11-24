import Foundation
import PurrdrCore

/// SSH 主機的過去 session 清單(#535):經主機通道跑一次性腳本,格式對齊主機服務的 `sessions.list`。
public enum SessionHistoryCommand {
    public static func command(kind: String, cwd: String) -> String { "" }
    static func arguments(in command: String) -> [String]? { nil }
    static func parse(_ stdout: Data) -> [ResumableSession] { [] }
}

public struct SSHSessionHistory: Sendable {
    let channel: any HostChannel
    let sleep: Sleep

    public init(channel: any HostChannel, sleep: @escaping Sleep = Sleeping.task) {
        self.channel = channel
        self.sleep = sleep
    }

    public func sessions(cwd: String, kind: String) async throws -> [ResumableSession] { [] }
}
