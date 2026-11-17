import Foundation
import PurrdrCore

/// 把圖片 bytes 經 exec 的 stdin 上傳到主機的 `~/.purrdr/uploads/`,回傳主機上的絕對路徑(行為規格 F7)。
public struct ImageUploader: ImageUploading {
    /// stdin 每次寫入的大小(中斷時能盡早發現)。
    static let chunkSize = 64 * 1024
    /// 單張上限(`ImageUploadLimit.maximumSize`)。
    public static let maximumSize = ImageUploadLimit.maximumSize

    let channel: any HostChannel
    let sleep: @Sendable (Duration) async throws -> Void

    public init(channel: any HostChannel, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.channel = channel
        self.sleep = sleep
    }

    /// 期限：20 秒(行為規格 F7「每個指令 20 秒」)加上以 32 KiB/s 估算的傳輸時間。
    static func deadline(forSize size: Int) -> Duration {
        .seconds(20) + .milliseconds(size / 32)
    }

    public func upload(_ data: Data, named name: UploadFileName) async throws -> String {
        guard data.count <= Self.maximumSize else { throw ImageUploadError.tooLarge }
        let session: any ExecSession
        do {
            session = try await channel.execute(ImageUploadCommand.posix(name: name, size: data.count))
        } catch {
            throw ImageUploadError.interrupted
        }
        let sleep = sleep
        let result: CommandResult? = try await withThrowingTaskGroup(of: CommandResult?.self) { group in
            group.addTask { try await Self.transfer(data, through: session) }
            group.addTask {
                try await sleep(Self.deadline(forSize: data.count))
                return nil
            }
            defer { group.cancelAll() }
            do {
                return try await group.next() ?? nil
            } catch {
                await session.close()
                throw error
            }
        }
        guard let result else {
            await session.close()
            throw ImageUploadError.deadlineExceeded
        }
        await session.close()
        if result.exitCode == Int32(HostScriptTimeLimit.exitCode) { throw ImageUploadError.deadlineExceeded }
        guard result.exitCode == 0 else { throw ImageUploadError.failed(exitCode: result.exitCode, message: result.stderrText) }
        let path = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        guard HostPathSyntax.isAbsolute(path, endingWith: name.value) else {
            throw ImageUploadError.unexpectedPath(path)
        }
        return path
    }

    /// 寫 bytes、送 EOF、讀到結束狀態。連線層的任何失敗、被訊號結束、沒有結束狀態就斷了，都是 `interrupted`。
    private static func transfer(_ data: Data, through session: any ExecSession) async throws -> CommandResult {
        do {
            var offset = data.startIndex
            while offset < data.endIndex {
                let end = data.index(offset, offsetBy: chunkSize, limitedBy: data.endIndex) ?? data.endIndex
                try await session.write(data[offset..<end])
                offset = end
            }
            await session.closeStdin()
            var result = CommandResult()
            var exited = false
            for try await event in session.output {
                switch event {
                case .stdout(let chunk): result.stdout.append(chunk)
                case .stderr(let chunk): result.stderr.append(chunk)
                case .exit(let code, let signal):
                    if signal != nil { throw ImageUploadError.interrupted }
                    result.exitCode = code
                    exited = true
                }
            }
            guard exited else { throw ImageUploadError.interrupted }
            return result
        } catch let error as CancellationError {
            throw error
        } catch let error as ImageUploadError {
            throw error
        } catch {
            throw ImageUploadError.interrupted
        }
    }
}
