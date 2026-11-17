import Foundation
import PurrdrCore

/// 主機上的一個資料夾與它的子資料夾(新增對話的資料夾瀏覽，行為規格 F3.3)。
public struct NewChatFolderListing: Sendable, Equatable {
    /// 主機上的絕對路徑(`~` 已展開)。
    public var path: String
    /// 子資料夾名稱：不含隱藏資料夾，含指向資料夾的 symlink,不分大小寫排序。
    public var folders: [String]

    public init(path: String, folders: [String]) {
        self.path = path
        self.folders = folders
    }
}

public enum NewChatFolderError: Error, Equatable {
    /// 主機上沒有這個資料夾(或不是資料夾、沒有權限進入)。帶使用者給的路徑。
    case notFound(String)
    /// 回應的第一行不是絕對路徑(例如登入設定印了東西)。
    case unexpectedResponse
    /// 其他失敗(腳本的 exit code 與 stderr)。
    case failed(exitCode: Int32?, stderr: String)
}

/// 新增對話用的主機資料夾：列出子資料夾，也用來在開始前把路徑解析成絕對路徑(F3.2 第 1 步)。
///
/// 為什麼開始前一定要先解析：herdr 對不存在的資料夾會**默默**改在家目錄建 workspace(行為規格 F3.2)。
///
/// 指令是 `/bin/sh -c '<腳本>' purrdr-dirs '<路徑>'`:不依賴使用者的登入 shell(可能是 fish),
/// 腳本與參數都不含反斜線(fish 在單引號內仍把 `\` 當特殊字元)。`~` 與 `~/…` 在主機上展開成 `$HOME`。
public struct NewChatFolders: Sendable {
    let channel: any HostChannel
    /// 指令期限的計時(測試注入)。
    let sleep: Sleep

    public init(channel: any HostChannel, sleep: @escaping Sleep = Sleeping.task) {
        self.channel = channel
        self.sleep = sleep
    }

    /// 列出 `path` 的子資料夾;`nil` 或空白 = 家目錄。資料夾不存在丟 `NewChatFolderError.notFound`。
    public func list(_ path: String?) async throws -> NewChatFolderListing {
        let requested = path ?? ""
        let result = try await channel.runOnce(Self.command(for: requested), deadline: HostCommandDeadline.standard, sleep: sleep) { session in
            try await session.read()
        }
        switch result.exitStatus {
        case .some(0):
            return try Self.parse(result.stdout)
        case .some(Self.notFoundExitCode):
            throw NewChatFolderError.notFound(requested.isEmpty ? "~" : requested)
        default:
            throw NewChatFolderError.failed(exitCode: result.exitStatus, stderr: String(decoding: result.stderr, as: UTF8.self))
        }
    }

    /// 解析成主機上的絕對路徑(`~` 展開、`cd` 得進去)。
    public func resolve(_ path: String) async throws -> String {
        try await list(path).path
    }

    // MARK: - 指令

    static let notFoundExitCode: Int32 = 66
    private static let tag = "purrdr-dirs"

    static let script = HostScriptTimeLimit.posixRead("""
        PATH=/usr/bin:/bin:$PATH
        export PATH
        nl='
        '
        d=$1
        case $d in
          '') d=$HOME ;;
          '~') d=$HOME ;;
          '~/'*) d=$HOME/${d#'~/'} ;;
        esac
        cd -- "$d" 2>/dev/null || exit 66
        pwd
        for f in *; do
          if [ -d "$f" ]; then printf '%s%s' "$f" "$nl"; fi
        done
        """)

    /// 列出某個路徑的指令(`""` = 家目錄)。
    public static func command(for path: String) -> String {
        ["/bin/sh", "-c", PosixShell.quote(script), tag, PosixShell.quote(path)].joined(separator: " ")
    }

    /// `command(for:)` 的反向：認得就回傳路徑參數，其他指令回 `nil`(Demo 主機用)。
    public static func requestedPath(in command: String) -> String? {
        let prefix = ["/bin/sh", "-c", PosixShell.quote(script), tag].joined(separator: " ") + " "
        guard command.hasPrefix(prefix), let arguments = PosixShell.unquote(String(command.dropFirst(prefix.count))),
              arguments.count == 1 else { return nil }
        return arguments[0]
    }

    /// 腳本的輸出(與 `parse` 相反;Demo 主機用)。
    public static func output(path: String, folders: [String]) -> Data {
        Data(([path] + folders).map { $0 + "\n" }.joined().utf8)
    }

    /// 第一行是 `pwd`(空 = `/`),之後每行一個子資料夾。
    static func parse(_ stdout: Data) throws -> NewChatFolderListing {
        var lines = String(decoding: stdout, as: UTF8.self).components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard let first = lines.first else { return NewChatFolderListing(path: "/", folders: []) }
        let path = first.isEmpty ? "/" : first
        guard HostPathSyntax.isAbsolute(path) else { throw NewChatFolderError.unexpectedResponse }
        let folders = lines.dropFirst().filter { !$0.isEmpty }.sorted {
            let order = $0.lowercased().compare($1.lowercased())
            return order == .orderedSame ? $0 < $1 : order == .orderedAscending
        }
        return NewChatFolderListing(path: path, folders: folders)
    }
}
