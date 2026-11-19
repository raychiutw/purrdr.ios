import Foundation
import PurrdrCore

/// SSH 的主機取檔(#225):每台主機一條長駐 exec 通道跑 `HostFileFetchScript`,一次一個請求;bytes 以 base64 分塊送回。
/// 主機跑不了腳本(Demo 主機)時丟 `HostFileFetchError.unsupported`;Windows 主機由 `WindowsHostChannel` 換成 PowerShell 版(#226)。
/// 通道不隨使用者關閉，閒置 60 秒由腳本自己結束(與主機檔案的長駐讀取分開，大檔不塞住主題、用量的讀取)。
public struct SSHHostFileFetcher: HostFileFetching {
    private let channel: LongRunningScriptChannel<HostFileFetchScript.Reply>

    /// - Parameter maximumSize: 主機端拒讀的大小上限(測試用小值)。
    public init(
        channel: any HostChannel, maximumSize: Int = HostFileFetchLimits.maximumSize, sleep: @escaping Sleep = Sleeping.task,
        diagnostics: (@Sendable (String) -> Void)? = nil
    ) {
        self.channel = LongRunningScriptChannel(
            name: "host file fetch", channel: channel, command: HostFileFetchScript.follow(maximumSize: maximumSize),
            deadline: HostCommandDeadline.standard, sleep: sleep, closesWhenUnused: false, diagnostics: diagnostics,
            takeReply: { try HostFileFetchScript.takeReply(from: &$0) })
    }

    public func status(of target: HostFileTarget) async throws -> HostFileStatus {
        switch try await request(HostFileFetchScript.statusRequest(target)) {
        case .status(let status): return status
        case .chunk, .changed: throw HostFileFetchError.failed("unexpected reply to stat")
        }
    }

    public func read(_ target: HostFileTarget, version: HostFileVersion, offset: Int, length: Int) async throws -> Data {
        switch try await request(HostFileFetchScript.readRequest(target, version: version, offset: offset, length: length)) {
        case .chunk(offset, let data): return data
        case .chunk: throw HostFileFetchError.failed("chunk at an unexpected offset")
        case .changed: throw HostFileFetchError.changed
        case .status(let status): throw HostFileFetchError.unavailable(status)
        }
    }

    private func request(_ line: Data) async throws -> HostFileFetchScript.Reply {
        do {
            switch try await channel.request(line) {
            case .reply(let reply): return reply
            case .unsupported: throw HostFileFetchError.unsupported
            }
        } catch let ended as LongRunningScriptChannel<HostFileFetchScript.Reply>.Ended {
            throw HostFileFetchError.failed("host file fetch channel ended (exit \(ended.exitCode.map(String.init) ?? "?"))")
        }
    }
}
