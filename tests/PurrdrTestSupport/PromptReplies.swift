import Foundation

/// 送出 prompt 相關的主機回應。
///
/// `agent.wait.matched.ndjson`、`error.agent-wait-timeout.ndjson` 是對本機 herdr 0.9.5 以唯讀的 `agent.wait` 錄下的;
/// `agent.prompt`、`pane.send_keys` 的回應**不錄**(會把文字或按鍵送進真的 agent),改以錄製檔為底，依
/// `herdr api schema --json`(`agent_prompted`、`ok` 結果)、`herdr agent prompt --help` 與執行檔字串
/// (`agent_prompt_stalled`、`agent_blocked`)改動。
public enum PromptReplies {
    /// `agent.prompt` 成功：以 `agent.wait` 的錄製成功回應為底，結果型別換成 `agent_prompted`(schema),
    /// 狀態換成 working(帶 `until` 時 herdr 只在觀察到狀態後才回)。`delivery` 只有 fork 會送(R-H23),用來模擬「無法驗證」。
    public static func prompted(delivery: String? = nil) -> FakeReply {
        .recorded("agent.wait.matched.ndjson") { response in
            guard var result = response["result"] as? [String: Any], var agent = result["agent"] as? [String: Any] else { return }
            agent["agent_status"] = "working"
            result["type"] = "agent_prompted"
            result["agent"] = agent
            if let delivery { result["delivery"] = delivery }
            response["result"] = result
        }
    }

    /// 以錄製的 herdr `timeout` 錯誤為底，換成其他錯誤碼與訊息。
    public static func error(_ code: String, _ message: String) -> FakeReply {
        .recorded("error.agent-wait-timeout.ndjson") { $0["error"] = ["code": code, "message": message] }
    }

    /// 按鍵送出成功(`pane.send_keys`)回 `{"type":"ok"}`;沿用同形狀的錄製回應(在場回報)。
    public static let keysAccepted = FakeReply.recorded("pane.report-metadata.ndjson")

    /// 主機收下請求但永遠不回(連線卡住)。
    public static let silent = FakeReply(trigger: .afterStdinLine, keepsOpen: true)
}
