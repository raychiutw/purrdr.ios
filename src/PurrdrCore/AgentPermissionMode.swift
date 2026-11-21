import Foundation

/// Claude Code 對話中的權限模式(#306)。Shift+Tab 在這幾個之間輪替。
///
/// 與新增聊天的 `ClaudePermissionMode`(啟動參數)不同:這是**執行中**從畫面讀到、再以按鍵切換的狀態。
/// 主機服務(0.7.0)沒有專屬的切換訊息(schema 只有 `agent.start` 的 `permission_mode`),所以兩種連線方式都用
/// 既有的 `pane.send_keys`(`shift+tab`)加 `pane.read` 對照畫面,切到目標模式為止。
public enum AgentPermissionMode: String, CaseIterable, Sendable {
    /// 每個動作都詢問(畫面上沒有模式標示)。
    case normal
    case acceptEdits
    case plan
    /// 略過權限(完全不詢問)。
    case bypassPermissions

    /// 按一次 Shift+Tab 到的下一個:一般 → 接受編輯 → Plan → 一般。略過權限不在預設輪替裡
    /// (啟動時沒開就按不出來),所以從它回到一般;要切進去只能從 sheet 選(主機沒開時會失敗並說明)。
    public func next() -> AgentPermissionMode {
        switch self {
        case .normal: .acceptEdits
        case .acceptEdits: .plan
        case .plan, .bypassPermissions: .normal
        }
    }

    /// 切換時最多送幾次 Shift+Tab(輪替最長 4 格,多留 1 次容錯)。
    public static let maximumSwitchAttempts = 5
}

/// 從 Pane 畫面認出目前的權限模式。
public enum PermissionModeScreen {
    /// 認不出(不是 Claude 的輸入畫面、被面板蓋住)回 `nil`,呼叫端沿用上次。
    /// 有模式時 Claude 在輸入框下一行顯示 `⏵⏵ accept edits on`、`⏸ plan mode on`、`⏵⏵ bypass permissions on`;
    /// 一般模式沒有模式標示,但有 `? for shortcuts`(閒置)或 `esc to interrupt`(工作中)。
    public static func parse(_ screen: String) -> AgentPermissionMode? {
        let lowered = screen.lowercased()
        if lowered.contains("bypass permissions on") { return .bypassPermissions }
        if lowered.contains("accept edits on") { return .acceptEdits }
        if lowered.contains("plan mode on") { return .plan }
        if lowered.contains("? for shortcuts") || lowered.contains("esc to interrupt") { return .normal }
        return nil
    }
}
