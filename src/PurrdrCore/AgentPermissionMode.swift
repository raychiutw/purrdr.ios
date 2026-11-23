import Foundation

/// Claude Code 對話中的權限模式(#306、#383)。Shift+Tab 在可用的模式之間輪替。
///
/// 與新增聊天的 `ClaudePermissionMode`(啟動參數)不同:這是**執行中**的狀態。以對話紀錄尾端最後一筆
/// 權限模式紀錄為準(`TranscriptMetadata.permissionMode`),畫面只補「剛切換、紀錄尚未寫入」的空檔。
/// 主機服務(0.7.0)沒有專屬的切換訊息(schema 只有 `agent.start` 的 `permission_mode`),所以兩種連線方式都用
/// 既有的 `pane.send_keys`(`shift+tab`)加 `pane.read` 對照畫面,切到目標模式為止。
public enum AgentPermissionMode: String, CaseIterable, Sendable {
    /// 每個動作都詢問(Claude 稱 manual／default;畫面上沒有模式標示)。
    case normal
    case acceptEdits
    case plan
    /// 略過權限(完全不詢問)。啟動時沒開就按不出來。
    case bypassPermissions
    /// 自動模式(由分類器代為核准)。要主機開啟才在輪替裡。
    case auto
    /// 不詢問、未預先允許的一律拒絕。只會從啟動參數或設定進入,Shift+Tab 輪替不會到,所以只顯示、不能切換。
    case dontAsk

    /// 預設就在輪替裡的模式。
    public static let defaultAvailable: Set<AgentPermissionMode> = [.normal, .acceptEdits, .plan]

    /// 面板選項的順序(與輪替順序一致;`dontAsk` 只在目前就是它時另外顯示)。
    public static let switchableOrder: [AgentPermissionMode] = [.normal, .acceptEdits, .plan, .bypassPermissions, .auto]

    /// 可以用 Shift+Tab 切到。
    public var isSwitchable: Bool { self != .dontAsk }

    /// 對話紀錄裡 `permissionMode` 欄位的值(Claude Code 寫 `default`、`acceptEdits`、`plan`、`auto`、
    /// `dontAsk`、`bypassPermissions`;也容許 `manual`、`bypass`)。不認得回 `nil`。
    public init?(transcriptValue: String) {
        switch transcriptValue {
        case "default", "manual", "normal": self = .normal
        case "acceptEdits": self = .acceptEdits
        case "plan": self = .plan
        case "bypassPermissions", "bypass": self = .bypassPermissions
        case "auto": self = .auto
        case "dontAsk": self = .dontAsk
        default: return nil
        }
    }

    /// 按一次 Shift+Tab 到的下一個,依 Claude Code 2.1.330 的輪替:一般 → 接受編輯 → Plan →
    /// (略過權限,若可用)→(自動,若可用)→ 一般。不在輪替裡的(`dontAsk`)按下去回到一般。
    public func next(available: Set<AgentPermissionMode> = AgentPermissionMode.defaultAvailable) -> AgentPermissionMode {
        switch self {
        case .normal: .acceptEdits
        case .acceptEdits: .plan
        case .plan:
            available.contains(.bypassPermissions) ? .bypassPermissions : available.contains(.auto) ? .auto : .normal
        case .bypassPermissions: available.contains(.auto) ? .auto : .normal
        case .auto, .dontAsk: .normal
        }
    }

    /// 切換時最多送幾次 Shift+Tab(輪替最長 5 格,多留 1 次容錯)。
    public static let maximumSwitchAttempts = 6
}

/// 這個 session 的 Shift+Tab 輪替裡有哪些模式(#383)。預設一般、接受編輯、Plan;畫面或紀錄上看過略過權限或自動、
/// 或從主機的 claude 啟動參數與設定判斷得出可用才加入。
public struct PermissionModeAvailability: Equatable, Sendable {
    public private(set) var modes: Set<AgentPermissionMode> = AgentPermissionMode.defaultAvailable

    public init() {}

    /// 看過這個模式(畫面標示或對話紀錄):略過權限與自動因此確定可用。
    public mutating func observe(_ mode: AgentPermissionMode) {
        if mode == .bypassPermissions || mode == .auto { modes.insert(mode) }
    }

    /// 從啟動指令與設定檔內容判斷:`--dangerously-skip-permissions`、`--allow-dangerously-skip-permissions`、
    /// `--permission-mode bypassPermissions|auto`(或 `=`)、`--enable-auto-mode`;設定的 `permissions.defaultMode`。
    public mutating func apply(launchCommand: String?, settingsJSON: [String]) {
        if let command = launchCommand {
            let words = command.split(whereSeparator: \.isWhitespace).map(String.init)
            if words.contains("--dangerously-skip-permissions") || words.contains("--allow-dangerously-skip-permissions") {
                modes.insert(.bypassPermissions)
            }
            if words.contains("--enable-auto-mode") { modes.insert(.auto) }
            for (index, word) in words.enumerated() {
                let value: String? = if word == "--permission-mode", index + 1 < words.count {
                    words[index + 1]
                } else if word.hasPrefix("--permission-mode=") {
                    String(word.dropFirst("--permission-mode=".count))
                } else {
                    nil
                }
                if let value, let mode = AgentPermissionMode(transcriptValue: value) { observe(mode) }
            }
        }
        for text in settingsJSON {
            guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let permissions = object["permissions"] as? [String: Any],
                  let value = permissions["defaultMode"] as? String,
                  let mode = AgentPermissionMode(transcriptValue: value) else { continue }
            observe(mode)
        }
    }

    /// 面板上列出的選項(依輪替順序);`current` 是 `dontAsk` 這類不能切換的模式時附在最後。
    public func options(current: AgentPermissionMode?) -> [AgentPermissionMode] {
        var list = AgentPermissionMode.switchableOrder.filter { modes.contains($0) }
        if let current, !list.contains(current) { list.append(current) }
        return list
    }
}

/// 從 Pane 畫面認出目前的權限模式。
public enum PermissionModeScreen {
    /// 認不出(不是 Claude 的輸入畫面、被面板蓋住)回 `nil`,呼叫端沿用上次。
    /// 有模式時 Claude 在輸入框下一行顯示 `⏵⏵ accept edits on`、`⏸ plan mode on`、`⏵⏵ auto mode on`、
    /// `⏵⏵ bypass permissions on`、`⏵⏵ don't ask on`;一般模式沒有標示,但有 `? for shortcuts`(閒置)或
    /// `esc to interrupt`(工作中);自訂 status line 會蓋掉這些,閒置時改以輸入框(兩條分隔線夾著 `❯`／`>`)判斷。
    public static func parse(_ screen: String) -> AgentPermissionMode? {
        let lowered = screen.lowercased()
        // 先看有明確標示的;一般模式沒有標示,最後才用「看起來是閒置輸入框」推。
        if lowered.contains("bypass permissions on") { return .bypassPermissions }
        if lowered.contains("accept edits on") { return .acceptEdits }
        if lowered.contains("auto mode on") { return .auto }
        if lowered.contains("don't ask on") || lowered.contains("don’t ask on") { return .dontAsk }
        if lowered.contains("plan mode on") { return .plan }
        if lowered.contains("manual mode on") { return .normal }
        if lowered.contains("? for shortcuts") || lowered.contains("esc to interrupt") { return .normal }
        return hasIdleInputBox(screen) ? .normal : nil
    }

    /// 閒置的輸入框:兩條 `────` 分隔線夾著一行以 `❯` 或 `>` 開頭的輸入列(也認 `│ > ` 框線版);
    /// `❯ 1. Yes` 這種編號選項是對話框,不算。
    static func hasIdleInputBox(_ screen: String) -> Bool {
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        func isRule(_ line: String) -> Bool { line.count >= 10 && line.allSatisfy { $0 == "─" || $0 == "━" } }
        func isPrompt(_ line: String) -> Bool {
            var text = line
            if text.hasPrefix("│") { text = text.dropFirst().trimmingCharacters(in: .whitespaces) }
            guard text.hasPrefix("❯") || text.hasPrefix(">") else { return false }
            let blanks = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{00A0}"))
            let rest = text.dropFirst().trimmingCharacters(in: blanks)
            return rest.wholeMatch(of: /\d+\..*/) == nil
        }
        for index in lines.indices where isPrompt(lines[index]) {
            if index > 0, isRule(lines[index - 1]), index + 1 < lines.count, isRule(lines[index + 1]) { return true }
        }
        return false
    }
}
