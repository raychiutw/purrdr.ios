import Foundation
import PurrdrCore

/// 在主機上一層層瀏覽資料夾：上一層與子資料夾的路徑，依主機的路徑語法(#26:Windows 是 `C:\…`)。
/// 檔案瀏覽(`FolderBrowserModel`)與新增對話的資料夾選擇(`FolderPickerModel`)共用。
struct FolderNavigation {
    /// 目前列出的資料夾;還沒讀到時是 `nil`。
    let current: String?

    /// 上一層;根目錄(`/`、`C:\`)或還沒讀到時是 `nil`。
    var parent: String? { current.flatMap(HostPathSyntax.parent(of:)) }

    var canGoUp: Bool { parent != nil }

    /// 子資料夾的路徑;還沒讀到時是 `nil`。
    func child(_ name: String) -> String? {
        current.map { HostPathSyntax.appending(name, to: $0) }
    }
}
