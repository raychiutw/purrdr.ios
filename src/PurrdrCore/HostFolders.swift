import Foundation

/// 資料夾清單裡的一個項目(行為規格 F13)。
public struct FolderEntry: Sendable, Equatable, Hashable {
    public enum Kind: Sendable, Equatable, Hashable {
        case folder
        case file
        /// symlink:不知道指向資料夾還是檔案,打開時才知道。
        case symlink
        /// 裝置、FIFO、socket 等。
        case other
    }

    public var name: String
    public var kind: Kind
    /// bytes;裝置檔是 0。
    public var size: Int64
    /// 修改時間(主機時區的年月日,今年內的項目另有時分)。
    public var modified: DateComponents?

    public init(name: String, kind: Kind, size: Int64, modified: DateComponents? = nil) {
        self.name = name
        self.kind = kind
        self.size = size
        self.modified = modified
    }
}

/// 一個資料夾的清單。
public struct FolderListing: Sendable, Equatable {
    /// 主機上的絕對路徑。
    public var path: String
    /// 資料夾在前,再依名稱。
    public var entries: [FolderEntry]

    public init(path: String, entries: [FolderEntry]) {
        self.path = path
        self.entries = entries
    }

    /// 解析清單指令的輸出：第一行是 `pwd`(必須是絕對路徑),接著是 `LC_ALL=C ls -lnA`。
    ///
    /// 認不得的行(`total N`、錯誤訊息)略過。`now` 用來補只有時分的日期的年份(ls 對半年內的項目不印年份)。
    public static func parse(_ output: String, now: Date = Date()) throws -> FolderListing {
        var lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first, HostPathSyntax.isAbsolute(String(first)) else { throw HostFolderError.notAFolderListing }
        lines.removeFirst()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let today = calendar.dateComponents([.year, .month, .day], from: now)
        let entries = lines.compactMap { LongFormatLine(String($0), today: today).entry }
        return FolderListing(path: String(first), entries: entries.sorted(by: Self.order))
    }

    /// 資料夾在前，再依名稱(不分大小寫)。
    static func order(_ a: FolderEntry, _ b: FolderEntry) -> Bool {
        if (a.kind == .folder) != (b.kind == .folder) { return a.kind == .folder }
        let (x, y) = (a.name.lowercased(), b.name.lowercased())
        return x == y ? a.name < b.name : x < y
    }
}

/// `ls -ln` 的一行:權限、連結數、uid、gid、大小(裝置檔是「主, 次」或 macOS 的 16 進位)、月、日、時分或年、名稱。
private struct LongFormatLine {
    var entry: FolderEntry?

    static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    init(_ line: String, today: DateComponents) {
        var rest = Substring(line)
        func next() -> Substring? {
            rest = rest.drop(while: { $0 == " " })
            guard !rest.isEmpty else { return nil }
            let token = rest.prefix(while: { $0 != " " })
            rest = rest.dropFirst(token.count)
            return token
        }
        guard let mode = next(), mode.count >= 10, next() != nil, next() != nil, next() != nil, var size = next() else { return }
        if size.hasSuffix(",") {
            // 「主, 次」:次編號是下一個欄位。
            guard let minor = next() else { return }
            size = minor
        }
        guard let monthText = next(), let month = Self.months.firstIndex(of: String(monthText)),
              let dayText = next(), let day = Int(dayText), let timeOrYear = next() else { return }
        // 名稱前恰好一個空白;名稱本身可以有空白。
        guard rest.first == " " else { return }
        var name = String(rest.dropFirst())
        guard !name.isEmpty else { return }

        let kind: FolderEntry.Kind
        switch mode.first {
        case "d": kind = .folder
        case "-": kind = .file
        case "l":
            kind = .symlink
            if let arrow = name.range(of: " -> ") { name = String(name[..<arrow.lowerBound]) }
        default: kind = .other
        }

        var modified = DateComponents(month: month + 1, day: day)
        if let colon = timeOrYear.firstIndex(of: ":") {
            guard let hour = Int(timeOrYear[..<colon]), let minute = Int(timeOrYear[timeOrYear.index(after: colon)...]),
                  let year = today.year, let thisMonth = today.month, let thisDay = today.day else { return }
            let isFuture = (month + 1, day) > (thisMonth, thisDay + 1)
            modified = DateComponents(year: isFuture ? year - 1 : year, month: month + 1, day: day, hour: hour, minute: minute)
        } else if let year = Int(timeOrYear) {
            modified.year = year
        } else {
            return
        }
        entry = FolderEntry(name: name, kind: kind, size: kind == .other ? 0 : Int64(size) ?? 0, modified: modified)
    }
}

public enum HostFolderError: Error, Equatable {
    /// 第一行不是絕對路徑:主機回應的不是資料夾清單。
    case notAFolderListing
    /// 資料夾打不開(不存在、不是資料夾、沒有權限);附上主機的錯誤訊息。
    case cannotOpen(String)
    /// 檔名不能上傳:空的、`.`、`..`、含 `/`、NUL 或換行。
    case invalidName
    /// 超過每檔上限(`HostFolders.maximumUploadSize`)。
    case tooLarge
    /// 這個資料夾已有同名項目:永不覆寫。
    case alreadyExists
    /// 連線在上傳途中斷了(或主機上的程序被訊號結束):主機上不會留下這個檔案。
    case interrupted
    case failed(exitCode: Int32, message: String)
    /// 主機回傳的路徑不是絕對路徑或不以 `/<檔名>` 結尾。
    case unexpectedPath(String)
    case deadlineExceeded
}

/// 瀏覽主機的資料夾、上傳檔案(行為規格 F13)。沒有 SFTP:清單是一個 exec,上傳的 bytes 走 exec 的 stdin(ADR-0003)。
///
/// 指令是 POSIX(macOS、Linux);Windows 主機由 `WindowsHostChannel` 換成同樣輸出格式的 PowerShell(`WindowsScripts`)。
public struct HostFolders: Sendable {
    /// 每檔上限 25 MB(十進位,與 iOS 顯示的檔案大小一致)。
    public static let maximumUploadSize = 25_000_000

    let channel: any HostChannel
    let deflate: (any RawDeflate)?
    let sleep: @Sendable (Duration) async throws -> Void

    /// - Parameter deflate: 有的話，一般檔案壓得小時以 gzip 傳輸(`UploadTransfer.prepare`)。
    public init(
        channel: any HostChannel, deflate: (any RawDeflate)? = nil,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.channel = channel
        self.deflate = deflate
        self.sleep = sleep
    }

    /// 列出資料夾;`path` 為 `nil` 時是家目錄。
    public func list(_ path: String? = nil) async throws -> FolderListing {
        let result = try await run(channel.execute(HostFolderCommand.list(path)), input: nil)
        if result.exitCode == HostFolderCommand.ExitCode.cannotOpen {
            throw HostFolderError.cannotOpen(result.stderrText)
        }
        return try FolderListing.parse(String(decoding: result.stdout, as: UTF8.self))
    }

    /// 上傳到 `folder`(絕對路徑),回傳主機上的絕對路徑。
    ///
    /// 大小與檔名在送出任何指令之前檢查;主機上已有同名項目時拒絕(永不覆寫)。
    public func upload(_ data: Data, named name: String, to folder: String) async throws -> String {
        guard data.count <= Self.maximumUploadSize else { throw HostFolderError.tooLarge }
        guard Self.isValidName(name) else { throw HostFolderError.invalidName }
        guard HostPathSyntax.isAbsolute(folder) else { throw HostFolderError.cannotOpen(folder) }
        let session: any ExecSession
        do {
            session = try await channel.execute(HostFolderCommand.upload(folder: folder, name: name, size: data.count))
        } catch {
            throw HostFolderError.interrupted
        }
        let sleep = sleep
        let result: CommandResult? = try await withThrowingTaskGroup(of: CommandResult?.self) { group in
            group.addTask { try await self.run(session, input: data) }
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
        await session.close()
        guard let result else { throw HostFolderError.deadlineExceeded }
        switch result.exitCode {
        case 0: break
        case HostFolderCommand.ExitCode.invalidName: throw HostFolderError.invalidName
        case HostFolderCommand.ExitCode.cannotOpen: throw HostFolderError.cannotOpen(result.stderrText)
        case HostFolderCommand.ExitCode.alreadyExists: throw HostFolderError.alreadyExists
        case HostFolderCommand.ExitCode.sizeMismatch: throw HostFolderError.interrupted
        default: throw HostFolderError.failed(exitCode: result.exitCode, message: result.stderrText)
        }
        let path = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        guard HostPathSyntax.isAbsolute(path, endingWith: name) else {
            throw HostFolderError.unexpectedPath(path)
        }
        return path
    }

    /// 檔名不可為空、`.`、`..`,不可含 `/`、NUL;也不可含換行(主機回傳的路徑以換行結尾)。
    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains { $0 == "/" || $0 == "\u{0}" || $0.isNewline }
    }

    /// 期限:20 秒加上以 32 KiB/s 估算的傳輸時間。
    static func deadline(forSize size: Int) -> Duration {
        .seconds(20) + .milliseconds(size / 32)
    }

    /// stdin 每次寫入的大小(中斷時能盡早發現)。
    static let chunkSize = 64 * 1024

    /// 寫 bytes(有的話)、送 EOF、讀到結束狀態。連線層失敗、被訊號結束、沒有結束狀態就斷了，都是 `interrupted`。
    private func run(_ session: any ExecSession, input: Data?) async throws -> CommandResult {
        do {
            if let input {
                var offset = input.startIndex
                while offset < input.endIndex {
                    let end = input.index(offset, offsetBy: Self.chunkSize, limitedBy: input.endIndex) ?? input.endIndex
                    do {
                        try await session.write(input[offset..<end])
                    } catch {
                        // 腳本可能已提早結束(資料夾打不開、檔名不行):不再寫，改讀它的結束狀態。
                        break
                    }
                    offset = end
                }
            }
            await session.closeStdin()
            var result = CommandResult()
            var exited = false
            for try await event in session.output {
                switch event {
                case .stdout(let chunk): result.stdout.append(chunk)
                case .stderr(let chunk): result.stderr.append(chunk)
                case .exit(let code, let signal):
                    if signal != nil { throw HostFolderError.interrupted }
                    result.exitCode = code
                    exited = true
                }
            }
            guard exited else { throw HostFolderError.interrupted }
            return result
        } catch let error as CancellationError {
            throw error
        } catch let error as HostFolderError {
            throw error
        } catch {
            throw HostFolderError.interrupted
        }
    }
}

/// 清單與上傳的主機指令(POSIX sh)。
///
/// - 指令是 `/bin/sh -c '<腳本>' <名稱> '<參數>'…`:不依賴使用者的登入 shell(可能是 fish)。腳本不含反斜線
///   (fish 在單引號內仍處理 `\`)、不明確 `exit 0`(行為規格 §3.2)。
/// - 清單：第一行 `pwd`,接著 `LC_ALL=C ls -lnA`(含隱藏檔;數字 uid 不洩漏使用者名稱;月份固定英文)。
/// - 上傳:bytes 走 stdin,寫到目的資料夾的隱藏暫存檔;收到的大小不同(中斷)就刪掉、失敗結束;
///   同名項目已存在則拒絕。以 `ln` 建立正式檔(已存在時失敗，不會有「檢查後被別人建立」的覆寫)。
///   `umask 077`:新檔只有本人可讀。
public enum HostFolderCommand {
    enum ExitCode {
        static let invalidName: Int32 = 64
        static let cannotOpen: Int32 = 66
        static let alreadyExists: Int32 = 73
        static let sizeMismatch: Int32 = 75
    }

    static let prelude = """
        PATH=/usr/bin:/bin:/usr/sbin:/sbin:$PATH
        LC_ALL=C
        export PATH LC_ALL

        """

    static let listScript = prelude + """
        if [ -n "$1" ]; then cd "$1" || exit 66; else cd || exit 66; fi
        pwd
        ls -lnA
        """

    static let uploadScript = prelude + """
        umask 077
        nl='
        '
        dir=$1
        name=$2
        size=$3
        case $name in
          '' | . | .. | */*) exit 64 ;;
        esac
        cd "$dir" || exit 66
        tmp=$(mktemp ./.purrdr-upload.XXXXXX) || exit 71
        trap 'rm -f "$tmp"' EXIT
        trap 'rm -f "$tmp"; exit 70' HUP INT TERM PIPE
        cat > "$tmp" || exit 72
        got=$(($(wc -c < "$tmp")))
        if [ "$got" != "$size" ]; then exit 75; fi
        if [ -e "./$name" ] || [ -L "./$name" ]; then exit 73; fi
        if ! ln "$tmp" "./$name" 2> /dev/null; then
          if [ -e "./$name" ] || [ -L "./$name" ]; then exit 73; fi
          exit 71
        fi
        d=$(pwd)
        if [ "$d" = / ]; then d=; fi
        printf '%s/%s%s' "$d" "$name" "$nl"
        """

    public static func list(_ path: String?) -> String {
        command(listScript, name: "purrdr-ls", arguments: [path ?? ""])
    }

    /// - Parameters:
    ///   - size: 原始大小(主機寫入的檔案大小)。
    ///   - transferSize: stdin 上的 bytes 數;`nil` 時同 `size`。
    public static func upload(
        folder: String, name: String, size: Int, encoding: UploadTransferEncoding = .identity, transferSize: Int? = nil
    ) -> String {
        command(uploadScript, name: "purrdr-put", arguments: [folder, name, String(size)])
    }

    private static func command(_ script: String, name: String, arguments: [String]) -> String {
        (["/bin/sh", "-c", PosixShell.quote(script), name] + arguments.map(PosixShell.quote)).joined(separator: " ")
    }

    /// Demo 主機用：認得清單指令就回傳要列的資料夾(`nil` = 家目錄)。
    public static func parseList(_ command: String) -> String?? {
        guard let arguments = arguments(of: command, script: listScript, name: "purrdr-ls"), arguments.count == 1 else { return nil }
        return .some(arguments[0].isEmpty ? nil : arguments[0])
    }

    /// Demo 主機與 Windows 通道用：認得上傳指令就回傳資料夾、檔名、原始大小、傳輸編碼與傳輸大小。
    public static func parseUpload(_ command: String)
        -> (folder: String, name: String, size: Int, encoding: UploadTransferEncoding, transferSize: Int)? {
        guard let arguments = arguments(of: command, script: uploadScript, name: "purrdr-put"), arguments.count == 3,
              let size = Int(arguments[2]) else { return nil }
        return (arguments[0], arguments[1], size, .identity, size)
    }

    private static func arguments(of command: String, script: String, name: String) -> [String]? {
        let prefix = ["/bin/sh", "-c", PosixShell.quote(script), name].joined(separator: " ") + " "
        guard command.hasPrefix(prefix) else { return nil }
        return PosixShell.unquote(String(command.dropFirst(prefix.count)))
    }
}
