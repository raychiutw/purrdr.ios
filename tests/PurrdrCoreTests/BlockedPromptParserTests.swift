import PurrdrCore
import PurrdrTestSupport
import Testing

/// 從 pane 畫面解析「需要你」的提示(行為規格 §5.1–§5.5、R-Q02、R-Q04、R-Q05–R-Q08、R-Q10)。
///
/// 畫面是依規格手寫的(`PaneScreens`,說明見 `Fixtures/README.md`)。
@Suite("解析需要你的提示")
struct BlockedPromptParserTests {
    static func parse(_ name: String, kind: String = "claude") throws -> BlockedPrompt {
        try #require(BlockedPromptParser.parse(screen: PaneScreens.text(name), agentKind: kind))
    }

    static func labels(_ prompt: BlockedPrompt) -> [String] { prompt.options.map(\.label) }

    // MARK: - 選單

    @Test("Claude Bash 權限：問題、編號選項、去掉結尾的快捷鍵提示、游標列;細節的標題與指令")
    func claudeBashPermission() throws {
        let prompt = try Self.parse("claude-bash")

        #expect(prompt.kind == .menu)
        #expect(prompt.question == "Do you want to proceed?")
        #expect(prompt.options.map(\.number) == [1, 2, 3])
        #expect(Self.labels(prompt) == [
            "Yes",
            "Yes, and don't ask again for npm test commands in /Users/demo/weather-app",
            "No, and tell Claude what to do differently",
        ])
        #expect(prompt.options.map(\.isCursor) == [true, false, false])
        #expect(prompt.isMultiSelect == false)
        #expect(prompt.details?.title == "Bash command")
        #expect(prompt.details?.content == ["npm test -- --runInBand forecast", "Run the forecast unit tests"])
        #expect(prompt.detailsOffscreen == false)
    }

    @Test("Claude Edit:兩條虛線框住內容(diff),之後才是問題")
    func claudeEditWithDashedContent() throws {
        let prompt = try Self.parse("claude-edit-dashed")

        #expect(prompt.question == "Do you want to make this edit to cache.ts?")
        #expect(prompt.details?.title == "Edit file")
        #expect(prompt.details?.summary == "src/cache.ts")
        #expect(prompt.details?.content.first == "12  export function cacheKey(city: string) {")
        #expect(prompt.details?.content.count == 4)
        #expect(Self.labels(prompt)[1] == "Yes, allow all edits during this session")
    }

    @Test("AskUserQuestion:分頁頭不是標題;選項下縮排的描述屬於選項，不是新選項")
    func askUserQuestion() throws {
        let prompt = try Self.parse("claude-ask-question")

        #expect(prompt.question == "Which color should the chart use?")
        #expect(Self.labels(prompt) == ["Blue", "Orange", "Green", "Type something."])
        #expect(prompt.details?.title == nil)
    }

    @Test("AskUserQuestion 單題(Claude Code 2026-11 真實畫面結構):題目前的「│ 」不算題目文字;「Chat about this」另列")
    func askUserQuestionSingle() throws {
        let prompt = try Self.parse("claude-ask-single")

        #expect(prompt.question == "Which color should the chart use?")
        #expect(Self.labels(prompt) == ["Blue", "Orange", "Green", "Type something.", "Chat about this"])
        #expect(prompt.chatOption?.number == 5)
    }

    @Test("AskUserQuestion 多選：勾選列與勾選狀態")
    func askUserQuestionMultiSelect() throws {
        let prompt = try Self.parse("claude-ask-multiselect")

        #expect(prompt.isMultiSelect)
        #expect(prompt.options.map(\.checked) == [true, false, false, false])
        #expect(Self.labels(prompt) == ["iPhone", "iPad", "Mac", "Type something"])
    }

    @Test("AskUserQuestion 檢閱畫面是普通選單")
    func askUserQuestionReview() throws {
        let prompt = try Self.parse("claude-ask-review")

        #expect(prompt.question == "Ready to submit your answers?")
        #expect(Self.labels(prompt) == ["Submit answers", "Cancel"])
        #expect(prompt.isMultiSelect == false)
    }

    @Test("超過 9 個選項全部顯示(編號照畫面),10 以上由按鍵規則停用")
    func moreThanNineOptions() throws {
        let prompt = try Self.parse("claude-many-options")

        #expect(prompt.options.map(\.number) == Array(1...11))
        #expect(prompt.options.filter { AnswerKeys.keys(for: .option($0), agentKind: "claude") == nil }.map(\.number) == [10, 11])
    }

    @Test("Grok 的 (●)/(○) 列;字母列不是選項")
    func grokRows() throws {
        let prompt = try Self.parse("grok-permission", kind: "grok")

        #expect(prompt.question == "Allow this command?")
        #expect(Self.labels(prompt) == ["Yes, proceed", "Yes, always allow in this session", "No, cancel"])
    }

    @Test("Codex:游標是 ›;Would you like to… 段落成為細節(指令是內容，散文是摘要)")
    func codexCommand() throws {
        let prompt = try Self.parse("codex-command", kind: "codex")

        #expect(prompt.options.map(\.number) == [1, 2, 3])
        #expect(prompt.options.first?.isCursor == true)
        #expect(Self.labels(prompt)[0] == "Yes, proceed")
        #expect(prompt.question == "Would you like to run the following command?")
        #expect(prompt.details?.content == ["$ cargo test -p forecast"])
        #expect(prompt.details?.summary == "Reason: Run the forecast tests")
    }

    @Test("Codex 的信任是一般編號選單")
    func codexTrustIsNumbered() throws {
        let prompt = try Self.parse("codex-trust", kind: "codex")

        #expect(prompt.kind == .menu)
        #expect(Self.labels(prompt) == ["Yes, continue", "No, quit"])
        #expect(AnswerKeys.keys(for: .option(prompt.options[0]), agentKind: "codex") == ["1", "enter"])
    }

    @Test("Codex 的 @ 檔案選擇器只能關閉(數字或 Enter 會把檔案插進 prompt)")
    func codexFilePicker() throws {
        let prompt = try Self.parse("codex-file-picker", kind: "codex")

        #expect(prompt.kind == .filePicker)
        #expect(prompt.options.isEmpty)
    }

    // MARK: - 資料夾信任

    @Test("Claude 資料夾信任：游標起在「No, exit」,所以 Yes 是 down + enter;沒有編號")
    func claudeTrust() throws {
        let prompt = try Self.parse("claude-trust")

        #expect(prompt.kind == .trust)
        #expect(prompt.options.map(\.number) == [nil, nil])
        let yes = try #require(prompt.options.first { $0.label == "Yes, I trust this folder" })
        let no = try #require(prompt.options.first { $0.label == "No, exit" })
        #expect(AnswerKeys.keys(for: .option(yes), agentKind: "claude") == ["down", "enter"])
        #expect(AnswerKeys.keys(for: .option(no), agentKind: "claude") == ["enter"])
        #expect(prompt.question == "Trust /Users/demo/weather-app? Claude Code will be able to read, edit, and run files there.")
    }

    @Test("Antigravity 資料夾信任：游標在 Yes;折行的資料夾接回一條路徑(不加空白)")
    func antigravityTrust() throws {
        let prompt = try Self.parse("agy-trust", kind: "agy")

        #expect(prompt.kind == .trust)
        let yes = try #require(prompt.options.first { $0.label == "Yes, I trust this folder" })
        let no = try #require(prompt.options.first { $0.label == "No, exit" })
        #expect(yes.keys == ["enter"])
        #expect(no.keys == ["down", "enter"])
        #expect(prompt.question == "Trust /Users/demo/Projects/weather-app/packages/forecast-service/src/hourly-cache-experiments? Antigravity will be able to read, edit, and run files there.")
    }

    // MARK: - 不是提示

    @Test("閒置的輸入框畫面(對話中的編號清單)不是提示")
    func idleScreenIsNotAPrompt() {
        #expect(BlockedPromptParser.parse(screen: PaneScreens.text("claude-idle"), agentKind: "claude") == nil)
    }

    @Test("ANSI 跳脫序列(含 ESC 與 OSC)先去掉")
    func stripsANSI() throws {
        let screen = "\u{1B}]0;title\u{07}Proceed with [TODO]?\n\u{1B}[1m❯ 1. Yes\u{1B}[0m\n  2. No\n"
        let prompt = try #require(BlockedPromptParser.parse(screen: screen, agentKind: "claude"))

        #expect(prompt.question == "Proceed with [TODO]?")
        #expect(Self.labels(prompt) == ["Yes", "No"])
    }

    @Test("最後一個連續選單勝出")
    func lastMenuWins() throws {
        let screen = "Old question?\n❯ 1. Old\n  2. Older\n\nNew question?\n❯ 1. Fresh\n  2. Fresher\n"
        let prompt = try #require(BlockedPromptParser.parse(screen: screen, agentKind: "claude"))

        #expect(prompt.question == "New question?")
        #expect(Self.labels(prompt) == ["Fresh", "Fresher"])
    }

    @Test("縮排在選項下、以 1. 開頭的行仍屬於上一個選項(#107)")
    func indentedNumberedLineBelongsToOption() throws {
        let screen = "Pick one?\n❯ 1. Plan A\n     1. first step\n     2. second step\n  2. Plan B\n"
        let prompt = try #require(BlockedPromptParser.parse(screen: screen, agentKind: "claude"))

        #expect(Self.labels(prompt) == ["Plan A", "Plan B"])
    }

    // MARK: - 簽章

    @Test("簽章：勾選狀態改變就不同;期限倒數(附註)改變不影響")
    func signature() throws {
        let checked = try Self.parse("claude-ask-multiselect")
        let toggled = try #require(BlockedPromptParser.parse(
            screen: PaneScreens.text("claude-ask-multiselect").replacingOccurrences(of: "2. [ ] iPad", with: "2. [✔] iPad"), agentKind: "claude"))
        #expect(checked.signature != toggled.signature)

        let base = PaneScreens.text("claude-bash")
        let early = base.replacingOccurrences(of: " Do you want", with: " ⚠ Will automatically deny this request in 1:30\n\n Do you want")
        let later = base.replacingOccurrences(of: " Do you want", with: " ⚠ Will automatically deny this request in 1:29\n\n Do you want")
        let first = try #require(BlockedPromptParser.parse(screen: early, agentKind: "claude"))
        let second = try #require(BlockedPromptParser.parse(screen: later, agentKind: "claude"))
        #expect(first.signature == second.signature)
        #expect(first.details?.note == "⚠ Will automatically deny this request in 1:30")
    }

    @Test("簽章含完整指令:連續兩個 cd /repo && … 指令不同")
    func signatureUsesWholeContent() throws {
        let base = PaneScreens.text("claude-bash")
        let one = base.replacingOccurrences(of: "   npm test -- --runInBand forecast\n", with: "   cd /repo &&\n   npm test\n")
        let two = base.replacingOccurrences(of: "   npm test -- --runInBand forecast\n", with: "   cd /repo &&\n   npm run lint\n")
        let first = try #require(BlockedPromptParser.parse(screen: one, agentKind: "claude"))
        let second = try #require(BlockedPromptParser.parse(screen: two, agentKind: "claude"))
        #expect(first.signature != second.signature)
    }

    @Test("提示開頭不在畫面上：標示細節在畫面外，且不把指令行升格為標題")
    func detailsOffscreen() throws {
        let screen = "   │ rm -rf build\n   │ swift build\n\n Do you want to proceed?\n ❯ 1. Yes\n   2. No\n"
        let prompt = try #require(BlockedPromptParser.parse(screen: screen, agentKind: "claude"))

        #expect(prompt.detailsOffscreen)
        #expect(prompt.details?.title == nil)
    }
}
