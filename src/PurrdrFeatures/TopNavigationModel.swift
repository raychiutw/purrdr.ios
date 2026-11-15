import Foundation
import Observation

/// iPhone 頂層導覽的 model:Agent 列表之上以 sheet 開啟的畫面(#37 故事 21)。
///
/// 不採 tab bar:列表工具列的「⋯」選單進入設定與主機，「+」新增對話;一次只開一個 sheet。
@MainActor
@Observable
public final class TopNavigationModel {
    /// 目前開著的 sheet;`nil` 表示停在 Agent 列表。
    public var sheet: TopLevelSheet?
    /// 等著匯入的主機分享連結(`purrdr://host?d=…`)。主機 sheet 開啟時帶入新增主機編輯器，之後清掉。
    public var pendingHostImport: URL?

    public init() {}

    /// 處理深層連結。認得就開對應畫面並回傳 `true`;不認得的連結不改變畫面。
    @discardableResult
    public func open(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == Self.urlScheme else { return false }
        switch url.host()?.lowercased() {
        case "settings":
            sheet = .settings
        case "host":
            // 系統相機掃 QR code 或點分享連結都會走到這裡;內容在主機 sheet 裡解析與說明。
            pendingHostImport = url
            sheet = .hosts
        default:
            return false
        }
        return true
    }

    /// app 註冊的 URL scheme(app 的 Info.plist `CFBundleURLTypes` 要一致)。
    public static let urlScheme = "purrdr"
}

/// 從 Agent 列表開啟的頂層 sheet。
public enum TopLevelSheet: String, Identifiable, Sendable {
    case settings
    case hosts
    case newChat
    /// 會員(登入、登入方式、刪除會員,#27)。設定頁(#32)做好後可改從設定進入。
    case member
    /// Purrdr Plus 的付費牆與訂閱摘要(#28)。
    case plus

    public var id: String { rawValue }
}
