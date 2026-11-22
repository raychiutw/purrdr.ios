/// herdr 回報的 agent 種類字串 → 正式名稱(herdr `src/detect/mod.rs`)。
///
/// herdr 的正式名稱是 `agy`、`opencode`、`copilot`;別名(`antigravity`、`antigravity-cli`、
/// `opencode2`、`open-code`、`github-copilot`、`ghcs`)與舊版 Purrdr 誤用的 `open_code`、`github_copilot`
/// 也換成正式名稱。所有依種類分流的判斷都先經這裡，不要各自比對字串。
public enum AgentKindName {
    public static func canonical(_ kind: String) -> String {
        switch kind {
        case "antigravity", "antigravity-cli": "agy"
        case "opencode2", "open-code", "open_code": "opencode"
        case "github-copilot", "ghcs", "github_copilot": "copilot"
        default: kind
        }
    }
}
