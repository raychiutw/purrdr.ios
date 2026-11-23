import Foundation

/// 主機服務的方案用量與用量擷取(`usage.*`、`claude_usage.*`,0.12.0 起)回的錯誤。
public enum PlanUsageError: Error, Equatable, Sendable {
    /// 主機上找不到 `codex`(`codex_not_found`)。
    case codexNotFound
    /// Codex 沒以 ChatGPT 登入(`codex_not_signed_in`)。
    case codexNotSignedIn
    /// Codex app-server 失敗、沒回應或回應看不懂(`codex_failed`;訊息是主機服務給的原因)。
    case codexFailed(String)
    /// Claude Code 的設定資料夾不存在,無法安裝用量擷取(`claude_not_found`)。
    case claudeNotFound
    /// Claude 的 settings.json 不是合法的 JSON 物件,沒有改動檔案(`claude_settings_not_json`)。
    case claudeSettingsNotJSON
    /// 用量擷取的檔案無法安全修改:安裝紀錄壞了、設定檔讀不到或讀取後被改過(`host_write_failed`;訊息是原因)。
    case hostWriteFailed(String)
}

/// 主機服務資料夾瀏覽 `directory.list`(0.12.0 起)回的錯誤。
public enum DirectoryListError: Error, Equatable, Sendable {
    /// 資料夾不存在或不是資料夾(`directory_not_found`)。
    case notFound
    /// 資料夾在排除清單或主機服務資料夾內(`directory_not_allowed`)。
    case notAllowed
    /// 讀不了這個資料夾(`directory_unreadable`)。
    case unreadable
}
