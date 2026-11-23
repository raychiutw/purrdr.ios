import Foundation
import PurrdrCore

/// 經主機通道讀 Claude Code 的模型目錄快取(#385):只跑專用唯讀指令 `ModelCatalogCommand`,走有期限的一次性入口。
/// 沒有快取(指令沒印東西)回 `nil`;指令跑不了(Windows、Demo 主機、HTTPS 主機)或逾時丟錯,由解析器退到下一層。
public struct SSHModelCatalogReader: HostModelCatalogReading {
    private let channel: any HostChannel
    private let sleep: Sleep

    public init(channel: any HostChannel, sleep: @escaping Sleep = Sleeping.task) {
        self.channel = channel
        self.sleep = sleep
    }

    public func readCache() async throws -> Data? {
        let result = try await channel.runOnce(ModelCatalogCommand.command(), deadline: HostCommandDeadline.probe, sleep: sleep) { session in
            try await session.read()
        }
        guard result.exitStatus == 0 else { throw ReadError.failed(exitStatus: result.exitStatus ?? -1) }
        let data = Data(result.stdoutText.utf8)
        return data.isEmpty ? nil : data
    }

    enum ReadError: Error, Equatable {
        case failed(exitStatus: Int32)
    }
}
