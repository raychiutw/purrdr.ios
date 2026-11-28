import Foundation

/// 主機服務的資料夾瀏覽(`directory.list`、`welcome.home_directory`,0.12.0 起):
/// 新增聊天的資料夾選擇器用它在 HTTPS 主機上瀏覽。`HTTPSHostConnection` 實作,測試用替身。
public protocol DirectoryBrowsing: Sendable {
    /// 主機服務版本(`HostServiceFeature.directoryBrowsing` 的門檻判斷用)。
    func hostServiceVersion() async throws -> String?
    /// 主機使用者家目錄;舊版主機服務或找不到時是 `nil`。
    func homeDirectory() async throws -> String?
    /// 列出絕對路徑底下的子資料夾。錯誤是 `DirectoryListError` 或 `HostServiceError`。
    func listDirectory(path: String) async throws -> HostServiceProtocol.DirectoryListResult
}
