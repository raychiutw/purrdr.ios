import Foundation
import PurrdrCore

/// 上傳到主機的 SSH 實作：bytes 經 exec 的 stdin 寫到主機系統暫存目錄底下的 `purrdr-uploads-<uid>/`,回傳主機上的絕對路徑(行為規格 F7、#286)。
public struct SSHHostUploader: HostUploading {
    /// stdin 每次寫入的大小(中斷時能盡早發現)。
    static let chunkSize = 64 * 1024
    /// 上限(`HostUploadLimit.maximumFileSize`)。
    public static let maximumSize = HostUploadLimit.maximumFileSize

    let channel: any HostChannel
    let sleep: Sleep

    public init(channel: any HostChannel, sleep: @escaping Sleep = Sleeping.task) {
        self.channel = channel
        self.sleep = sleep
    }

    /// 經一次性指令的入口(`runOnce`),期限是 `HostCommandDeadline.upload`;逾時(含主機腳本自己逾時)丟 `deadlineExceeded`,
    /// 連線層失敗、被訊號結束、沒有結束狀態就斷了都是 `interrupted`。
    public func upload(_ data: Data, named name: HostUploadName) async throws -> String {
        guard data.count <= Self.maximumSize else { throw HostUploadError.tooLarge }
        let result: CommandResult
        do {
            result = try await channel.runOnce(
                HostUploadCommand.posix(name: name, size: data.count), deadline: HostCommandDeadline.upload(bytes: data.count), sleep: sleep
            ) { session in
                try await Self.transfer(data, through: session)
            }
        } catch HostCommandError.deadlineExceeded {
            throw HostUploadError.deadlineExceeded
        } catch let error as CancellationError {
            throw error
        } catch let error as HostUploadError {
            throw error
        } catch {
            throw HostUploadError.interrupted
        }
        guard result.exitCode == 0 else { throw HostUploadError.failed(exitCode: result.exitCode, message: result.stderrText) }
        let path = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        guard HostPathSyntax.isAbsolute(path, endingWith: name.value) else {
            throw HostUploadError.unexpectedPath(path)
        }
        return path
    }

    /// 寫 bytes、送 EOF、讀到結束狀態。被訊號結束或沒有結束狀態就斷了是 `interrupted`。
    private static func transfer(_ data: Data, through session: any ExecSession) async throws -> CommandResult {
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = data.index(offset, offsetBy: chunkSize, limitedBy: data.endIndex) ?? data.endIndex
            try await session.write(data[offset..<end])
            offset = end
        }
        await session.closeStdin()
        let result = try await session.read()
        guard result.didExit, result.signal == nil else { throw HostUploadError.interrupted }
        return result
    }
}
