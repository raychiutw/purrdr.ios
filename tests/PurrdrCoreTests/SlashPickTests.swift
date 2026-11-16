import PurrdrCore
import Testing

/// 點選 slash 指令時的行為(#45、行為規格 F9.3、R-C05):不需參數的直接送出;必填參數只填入並提示;
/// 有副作用或破壞性的只填入、不送出。
@Suite("Slash 點選行為")
struct SlashPickTests {
    @Test("不需參數、選填參數(`[model]`、`<optional …>`)→ 直接送出")
    func noArgumentsSendImmediately() {
        #expect(SlashPick.action(for: SlashCommand(name: "context", summary: "Show context usage")) == .send)
        #expect(SlashPick.action(for: SlashCommand(name: "model", argumentHint: "[model]", summary: "Choose the model")) == .send)
        #expect(SlashPick.action(for: SlashCommand(name: "export", argumentHint: "<optional filename>", summary: "Export")) == .send)
    }

    @Test("必填參數(任何一段 `<…>` 不含 optional)→ 填入 `/名稱 `,游標後提示參數")
    func requiredArgumentFillsWithHint() {
        #expect(SlashPick.action(for: SlashCommand(name: "add-dir", argumentHint: "<path>", summary: "Add a working directory")) == .fill(hint: "<path>"))
        #expect(SlashPick.action(for: SlashCommand(name: "loop", argumentHint: "[interval] <prompt>", summary: "Run on an interval")) == .fill(hint: "[interval] <prompt>"))
    }

    @Test("有副作用的內建指令(compact、clear、init、exit…)只填入不送出;選填參數照樣提示")
    func sideEffectsOnlyFill() {
        for name in ["exit", "quit", "logout", "restart", "stop", "clear", "delete", "archive", "home", "commit", "pr", "commit-push-pr", "compact", "init", "new"] {
            #expect(SlashPick.action(for: SlashCommand(name: name, summary: "")) == .fill(hint: nil), "\(name)")
        }
        #expect(SlashPick.action(for: SlashCommand(name: "compact", argumentHint: "[instructions]", summary: "Compact")) == .fill(hint: "[instructions]"))
        // plugin 或使用者指令：名稱有命名空間時看最後一段。
        #expect(SlashPick.action(for: SlashCommand(name: "kit:commit", summary: "Write a message")) == .fill(hint: nil))
    }

    @Test("說明含 commit／push／reset／delete／overwrite(不分大小寫)的也只填入")
    func sideEffectSummariesOnlyFill() {
        #expect(SlashPick.action(for: SlashCommand(name: "ship", summary: "Commit and PUSH the branch")) == .fill(hint: nil))
        #expect(SlashPick.action(for: SlashCommand(name: "wipe", summary: "Reset the working tree")) == .fill(hint: nil))
        #expect(SlashPick.action(for: SlashCommand(name: "save", summary: "Overwrite the snapshot")) == .fill(hint: nil))
        #expect(SlashPick.action(for: SlashCommand(name: "tidy", summary: "Delete stale branches")) == .fill(hint: nil))
        #expect(SlashPick.action(for: SlashCommand(name: "review", summary: "Review a pull request")) == .send)
    }
}
