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

    public init() {}

    /// 處理深層連結。認得就開對應畫面並回傳 `true`;不認得的連結不改變畫面。
    @discardableResult
    public func open(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == Self.urlScheme,
              url.host()?.lowercased() == "settings"
        else { return false }
        sheet = .settings
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
