import Foundation

/// 在 slash 選單點選一個指令時要做什麼(#45、行為規格 F9.3、R-C05)。
public enum SlashPick: Sendable, Equatable {
    /// 立刻送出 `/名稱`(被拒時文字放回輸入框)。
    case send
    /// 只把 `/名稱 ` 填進輸入框，由使用者自己按送出;`hint` 是游標後淡淡顯示的參數提示。
    case fill(hint: String?)

    /// 有副作用或破壞性的指令名稱(名稱有命名空間時看最後一段):點了只填入、不送出。
    public static let sideEffectNames: Set<String> = [
        "exit", "quit", "logout", "restart", "stop", "clear", "delete", "archive", "home",
        "commit", "pr", "commit-push-pr", "compact", "init", "new",
    ]

    /// 說明含這些字(不分大小寫)的指令也視為有副作用。
    public static let sideEffectWords = ["commit", "push", "reset", "delete", "overwrite"]

    /// 決定點選的行為。
    ///
    /// - 有副作用 → 只填入(有參數提示就照樣提示)。
    /// - 有必填參數(任何一段 `<…>` 且不含 `optional`)→ 填入並提示。規格寫「以 `<` 開頭」;
    ///   `[interval] <prompt>` 這種選填在前、必填在後的提示也算必填，否則送出後只會被 agent 拒絕。
    /// - 其他(沒有參數，或 `[model]`、`<optional …>` 這類選填)→ 直接送出。
    public static func action(for command: SlashCommand) -> SlashPick {
        if isSideEffect(command) { return .fill(hint: command.argumentHint) }
        if let hint = command.argumentHint, hasRequiredArgument(hint) { return .fill(hint: hint) }
        return .send
    }

    static func isSideEffect(_ command: SlashCommand) -> Bool {
        let base = command.name.split(separator: ":").last.map(String.init) ?? command.name
        if sideEffectNames.contains(base.lowercased()) { return true }
        let summary = command.summary.lowercased()
        return sideEffectWords.contains { summary.contains($0) }
    }

    static func hasRequiredArgument(_ hint: String) -> Bool {
        hint.matches(of: /<[^>]*>?/).contains { !$0.output.lowercased().contains("optional") }
    }
}
