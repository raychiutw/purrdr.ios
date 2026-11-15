import Foundation

/// Purrdr 後台與 Google 登入的設定。
///
/// 標成 REPLACE_ME 的值上線前要換成真值(清單見 backend/README.md「上線前要填的東西」)。
/// 還是佔位符時，登入會因為連不上而顯示錯誤，聊天與終端機不受影響。
enum BackendConfiguration {
    /// 部署後的 Worker 網址。
    static let baseURL = URL(string: "https://purrdr-backend.REPLACE-ME.workers.dev")!

    /// Google Cloud Console 的 iOS OAuth client ID(與後台 `GOOGLE_CLIENT_IDS` 相同)。
    static let googleClientID = "REPLACE-ME.apps.googleusercontent.com"
}
