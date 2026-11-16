import Foundation
import PurrdrCore

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

/// 推播(#29)。
enum PushSettings {
    /// 主機外掛的公開 repo(`herdr plugin install` 的來源)。發佈 `host-plugin/` 的公開 repo 前是佔位(見 backend/README.md 上線清單)。
    static let pluginSource = "raychiutw/purrdr-host-plugin"

    /// 主機外掛呼叫的後台網址，寫進主機上的配對檔。
    static var endpoint: URL { BackendConfiguration.baseURL.appending(path: "v1/push") }

    /// APNs 環境:Xcode 直接安裝的 Debug build 拿到的是 sandbox token,TestFlight／App Store 是 production。
    static var environment: MemberSession.PushEnvironment {
        #if DEBUG
        .sandbox
        #else
        .production
        #endif
    }
}
