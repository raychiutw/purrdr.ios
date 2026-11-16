import Foundation

/// 上傳到主機的圖片檔名(行為規格 F7):只允許 `[A-Za-z0-9-]+\.(jpg|png)`。
///
/// 檔名會原樣交給主機腳本、也會出現在 prompt 裡，所以在 app 端就擋掉其他字元。
public struct UploadFileName: Hashable, Sendable {
    public let value: String

    public init?(_ value: String) {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, ["jpg", "png"].contains(parts[1]), !parts[0].isEmpty, parts[0].allSatisfy(allowed.contains) else {
            return nil
        }
        self.value = value
    }

    /// `<時間(毫秒)base36>-<8 個 base36 亂數>.jpg`。
    public static func make(date: Date, random: inout some RandomNumberGenerator) -> UploadFileName {
        let digits = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        let millis = Int64(max(0, date.timeIntervalSince1970 * 1000))
        let suffix = String((0..<8).map { _ in digits[Int.random(in: 0..<36, using: &random)] })
        return UploadFileName("\(String(millis, radix: 36))-\(suffix).jpg")!
    }
}

public enum ImageUploadError: Error, Equatable {
    /// 連線在上傳途中斷了(或主機上的程序被訊號結束):主機上不會留下這張圖。
    case interrupted
    /// 主機腳本失敗(非零 exit;例如磁碟滿、同名檔案已存在)。
    case failed(exitCode: Int32, message: String)
    /// 主機回傳的路徑不是絕對路徑或不以 `/<檔名>` 結尾:主機把圖片存到意外的位置。
    case unexpectedPath(String)
    case deadlineExceeded
    /// 超過單張上限(`ImageUploader.maximumSize`)。
    case tooLarge
}

/// 圖片上傳的主機指令(POSIX;Windows 主機由 `WindowsHostChannel` 換成 `WindowsScripts.imageUpload`)。
///
/// - 指令只帶檔名與大小,bytes 走 exec 的 stdin(ADR-0003:沒有 SFTP;也避開 sshd 單一參數 128 KiB 的上限)。
///   app 送完 bytes 後送 EOF。
/// - 寫到 `~/.purrdr/uploads/` 的隱藏暫存檔，收到的大小與宣告的不同(上傳中斷)就刪掉暫存檔、失敗結束;
///   相同才 `mv` 成正式檔。同名檔案已存在則拒絕，永不覆寫(§8.4)。
/// - `umask 077`,上傳資料夾強制 700:只有本人可讀。
/// - 成功後刪掉上傳資料夾裡 7 天(10,080 分鐘)前的檔案(含中斷留下的暫存檔),印出絕對路徑。
/// - 腳本不含反斜線(fish 在單引號內仍處理 `\`)、不明確 `exit 0`(行為規格 §3.2)。
public enum ImageUploadCommand {
    static let script = """
        PATH=/usr/bin:/bin:/usr/sbin:/sbin:$PATH
        LC_ALL=C
        export PATH LC_ALL
        umask 077
        name=$1
        size=$2
        case $name in
          '' | .* | *[!A-Za-z0-9.-]*) exit 64 ;;
        esac
        d=$HOME/.purrdr/uploads
        mkdir -p "$d" || exit 71
        chmod 700 "$d" || exit 71
        tmp=$(mktemp "$d/.upload.XXXXXX") || exit 71
        trap 'rm -f "$tmp"' EXIT
        trap 'rm -f "$tmp"; exit 70' HUP INT TERM PIPE
        cat > "$tmp" || exit 72
        got=$(($(wc -c < "$tmp")))
        if [ "$got" != "$size" ]; then exit 75; fi
        if [ -e "$d/$name" ] || [ -L "$d/$name" ]; then exit 73; fi
        mv "$tmp" "$d/$name" || exit 71
        tmp=
        find "$d" -type f -mmin +10080 -exec rm -f {} + 2> /dev/null
        printf '%s/%s
        ' "$d" "$name"
        """

    public static func posix(name: UploadFileName, size: Int) -> String {
        ["/bin/sh", "-c", PosixShell.quote(script), "purrdr-upload", PosixShell.quote(name.value), PosixShell.quote(String(size))].joined(separator: " ")
    }

    /// Demo 主機用：認得上傳指令就回傳檔名與大小。
    public static func parse(_ command: String) -> (name: UploadFileName, size: Int)? {
        let prefix = ["/bin/sh", "-c", PosixShell.quote(script), "purrdr-upload"].joined(separator: " ") + " "
        guard command.hasPrefix(prefix) else { return nil }
        let arguments = PosixShell.unquote(String(command.dropFirst(prefix.count))) ?? []
        guard arguments.count == 2, let name = UploadFileName(arguments[0]), let size = Int(arguments[1]) else { return nil }
        return (name, size)
    }
}

/// 把圖片 bytes 經 exec 的 stdin 上傳到主機的 `~/.purrdr/uploads/`,回傳主機上的絕對路徑(行為規格 F7)。
public struct ImageUploader: Sendable {
    /// stdin 每次寫入的大小(中斷時能盡早發現)。
    static let chunkSize = 64 * 1024
    /// 單張上限(手機端已縮到 2048px JPEG,正常遠小於此)。
    public static let maximumSize = 20 * 1024 * 1024

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
