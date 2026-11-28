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
    /// 不能瀏覽的主機(HTTPS)要給絕對路徑。帶使用者給的路徑。
    case absolutePathRequired(String)
    /// 主機服務沒回報家目錄(找不到),沒辦法從家目錄開始。
    case homeUnavailable
}

/// 新增對話用的主機資料夾：列出子資料夾，也用來在開始前把路徑解析成絕對路徑(F3.2 第 1 步)。
///
/// 為什麼開始前一定要先解析：herdr 對不存在的資料夾會**默默**改在家目錄建 workspace(行為規格 F3.2)。
///
/// 指令是 `/bin/sh -c '<腳本>' purrdr-dirs '<路徑>'`:不依賴使用者的登入 shell(可能是 fish),
/// 腳本與參數都不含反斜線(fish 在單引號內仍把 `\` 當特殊字元)。`~` 與 `~/…` 在主機上展開成 `$HOME`。
public struct NewChatFolders: Sendable {
    /// `nil`:沒有主機通道(HTTPS 主機),不能瀏覽也不能展開 `~`。
    let channel: (any HostChannel)?
    /// HTTPS 主機的資料夾瀏覽(主機服務 0.12.0 起,#731);版本不足時 `browsingAvailability()` 說明。
    let browser: (any DirectoryBrowsing)?
    /// 指令期限的計時(測試注入)。
    let sleep: Sleep

    public init(channel: any HostChannel, sleep: @escaping Sleep = Sleeping.task) {
        self.channel = channel
        browser = nil
        self.sleep = sleep
    }

    /// HTTPS 主機:經主機服務瀏覽資料夾(要先以 `browsingAvailability()` 確認版本)。
    public init(browser: any DirectoryBrowsing) {
        channel = nil
        self.browser = browser
        sleep = Sleeping.task
    }

    private init() {
        channel = nil
        browser = nil
        sleep = Sleeping.task
    }

    public enum BrowsingAvailability: Sendable, Equatable {
        case available
        /// 主機服務比 0.12.0 舊(帶目前版本)。
        case hostServiceUpdateRequired(installedVersion: String)
        /// 讀不到版本(沒連上等):先當作不能瀏覽,不說要更新。
        case unknown
    }

    /// 這個主機現在能不能瀏覽資料夾。SSH 一律可以;HTTPS 看主機服務版本。
    public func browsingAvailability() async -> BrowsingAvailability {
        if channel != nil { return .available }
        guard let browser else { return .unknown }
        guard let version = try? await browser.hostServiceVersion() else { return .unknown }
        return HostServiceFeature.directoryBrowsing.isAvailable(onHostServiceVersion: version)
            ? .available : .hostServiceUpdateRequired(installedVersion: version)
    }

    /// 沒有瀏覽能力的 HTTPS 主機(#287):只收絕對路徑;資料夾存不存在由主機服務在建立 workspace 時檢查。
    public static let absolutePathsOnly = NewChatFolders()

    /// 能不能在主機上瀏覽資料夾。
    /// HTTPS 主機的瀏覽要先過 `browsingAvailability()`,所以這裡只對 SSH 為真。
    public var canBrowse: Bool { channel != nil }

    /// 有主機服務的瀏覽能力可以問(版本還要查)。
    public var hasHostServiceBrowser: Bool { browser != nil }

    /// 列出 `path` 的子資料夾;`nil` 或空白 = 家目錄。資料夾不存在丟 `NewChatFolderError.notFound`。
    public func list(_ path: String?) async throws -> NewChatFolderListing {
        if let browser { return try await listViaHostService(browser, path) }
        guard let channel else { throw HostServiceError.unsupported("folders") }
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
        if let browser {
            // 只展開 `~`;資料夾存不存在由主機服務在建立 workspace 時檢查。
            if path == "~" || path.hasPrefix("~/") {
                guard let home = try await browser.homeDirectory(), !home.isEmpty else { throw NewChatFolderError.absolutePathRequired(path) }
                return path == "~" ? home : Self.join(home, String(path.dropFirst(2)))
            }
            guard HostPathSyntax.isAbsolute(path) else { throw NewChatFolderError.absolutePathRequired(path) }
            return path
        }
        guard canBrowse else {
            guard HostPathSyntax.isAbsolute(path) else { throw NewChatFolderError.absolutePathRequired(path) }
            return path
        }
        return try await list(path).path
    }

    // MARK: - 主機服務

    private func listViaHostService(_ browser: any DirectoryBrowsing, _ path: String?) async throws -> NewChatFolderListing {
        let requested = path.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let target: String
        if requested.isEmpty || requested == "~" || requested.hasPrefix("~/") {
            guard let home = try await browser.homeDirectory(), !home.isEmpty else { throw NewChatFolderError.homeUnavailable }
            target = requested.hasPrefix("~/") ? Self.join(home, String(requested.dropFirst(2))) : home
        } else {
            target = requested
        }
        let result = try await browser.listDirectory(path: target)
        // 與 SSH 一致:不列隱藏資料夾,不分大小寫排序。
        let folders = result.directories.filter { !$0.isEmpty && !$0.hasPrefix(".") }.sorted {
            let order = $0.lowercased().compare($1.lowercased())
            return order == .orderedSame ? $0 < $1 : order == .orderedAscending
        }
        return NewChatFolderListing(path: result.path, folders: folders)
    }

    private static func join(_ base: String, _ rest: String) -> String {
        guard !rest.isEmpty else { return base }
        let separator = base.hasSuffix("/") || base.hasSuffix("\\") ? "" : "/"
        return base + separator + rest
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
