import Foundation

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

    /// 不分大小寫排序(同名時以原字串決定),所有實作共用,輸出順序才一致。
    public static func sorted(_ names: [String]) -> [String] {
        names.sorted {
            let order = $0.lowercased().compare($1.lowercased())
            return order == .orderedSame ? $0 < $1 : order == .orderedAscending
        }
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

/// 資料夾瀏覽現在能不能用。
public enum NewChatFolderBrowsingAvailability: Sendable, Equatable {
    case available
    /// 主機服務比 0.12.0 舊(帶目前版本)。
    case hostServiceUpdateRequired(installedVersion: String)
    /// 讀不到版本(沒連上等)或這個主機沒有瀏覽能力:先當作不能瀏覽,不說要更新。
    case unknown
}

/// 新增對話用的主機資料夾:列出子資料夾,也用來在開始前把路徑解析成絕對路徑(F3.2 第 1 步)。
///
/// 為什麼開始前一定要先解析：herdr 對不存在的資料夾會**默默**改在家目錄建 workspace(行為規格 F3.2)。
///
/// Seam:上層(`NewChatLauncher`、`NewChatModel`、`FolderPickerModel`)只認這個介面;
/// adapter 依連線方式各一個——SSH(`SSHNewChatFolders`,`PurrdrSSH`)、
/// 主機服務(`HostServiceNewChatFolders`,`PurrdrHTTPS`)、沒有瀏覽能力(`AbsolutePathNewChatFolders`)。
public protocol NewChatFolderBrowsing: Sendable {
    /// 不必先查就能瀏覽(SSH 為真;HTTPS 要先過 `browsingAvailability()`)。
    var canBrowse: Bool { get }
    func browsingAvailability() async -> NewChatFolderBrowsingAvailability
    /// 列出 `path` 的子資料夾;`nil` 或空白 = 家目錄。資料夾不存在丟 `NewChatFolderError.notFound`。
    func list(_ path: String?) async throws -> NewChatFolderListing
    /// 解析成主機上的絕對路徑。
    func resolve(_ path: String) async throws -> String
}

/// 沒有瀏覽能力的 HTTPS 主機(#287):只收絕對路徑;資料夾存不存在由主機服務在建立 workspace 時檢查。
public struct AbsolutePathNewChatFolders: NewChatFolderBrowsing {
    public init() {}

    public var canBrowse: Bool { false }

    public func browsingAvailability() async -> NewChatFolderBrowsingAvailability { .unknown }

    public func list(_ path: String?) async throws -> NewChatFolderListing {
        throw HostServiceError.unsupported("folders")
    }

    public func resolve(_ path: String) async throws -> String {
        guard HostPathSyntax.isAbsolute(path) else { throw NewChatFolderError.absolutePathRequired(path) }
        return path
    }
}
