import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrTestSupport
@testable import PurrdrFeatures
import Testing

/// 輸入列上方的 slash 選單(#15):輸入 `/` 時出現、依來源分組、可搜尋、鍵盤可選。
@MainActor
@Suite("Slash 選單")
struct SlashMenuModelTests {
    nonisolated static let catalog = SlashCatalog(sections: [
        SlashSection(source: .builtIn, commands: [
            SlashCommand(name: "clear", summary: "Clear the conversation history"),
            SlashCommand(name: "model", argumentHint: "[model]", summary: "Choose the model"),
        ]),
        SlashSection(source: .plugin("mattpocock-skills"), commands: [
            SlashCommand(name: "mattpocock-skills:implement", summary: "Implement a ticket"),
            SlashCommand(name: "mattpocock-skills:tdd", summary: "Test-driven development"),
        ]),
    ], isComplete: true)

    static func menu(_ catalog: SlashCatalog? = catalog) -> SlashMenuModel {
        SlashMenuModel(loader: { catalog })
    }

    @Test("文中上色用的已知名稱:載入後是非內建指令，內建指令(只在開頭有意義)不算(#469)")
    func inlineNames() async {
        let menu = Self.menu()
        #expect(menu.inlineNames.isEmpty, "還沒載入時是空集合")
        menu.update(draft: "/")
        await menu.load()
        #expect(menu.inlineNames == ["mattpocock-skills:implement", "mattpocock-skills:tdd"])
    }

    @Test("游標前是 / 加名稱字元時才出現;接著打空白就收起")
    func visibilityFollowsDraft() async {
        let menu = Self.menu()
        menu.update(draft: "hello")
        #expect(!menu.isVisible)
        menu.update(draft: "/")
        await menu.load()
        #expect(menu.isVisible)
        #expect(menu.sections.map(\.source) == [.builtIn, .plugin("mattpocock-skills")])
        menu.update(draft: "/model ")
        #expect(!menu.isVisible)
        menu.update(draft: "x/model")
        #expect(!menu.isVisible)
        menu.update(draft: "/mattpocock-skills:t")
        #expect(menu.isVisible)
    }

    @Test("文字中間「空格＋/」與換行後的 / 叫出文中選單，只列 skill 與自訂指令")
    func inlineTriggerListsOnlySkills() async {
        let menu = Self.menu()
        menu.update(draft: "先跑 /", caret: 4)
        await menu.load()
        #expect(menu.isVisible)
        #expect(menu.trigger?.placement == .inline)
        #expect(menu.sections.map(\.source) == [.plugin("mattpocock-skills")])
        menu.update(draft: "第一行\n/td", caret: 7)
        #expect(menu.isVisible)
        #expect(menu.trigger == SlashMenuModel.Trigger(range: 4..<7, query: "td", placement: .inline))
        #expect(menu.ranked?.map(\.name) == ["mattpocock-skills:tdd"])
    }

    @Test(
        "網址、路徑、分數、/ 後接空白、有選取範圍都不觸發",
        arguments: [
            ("a/b", 3 as Int?), ("看 https://x/y", 13), ("1/2", 3), ("先跑 / ", 5), ("先跑 /rev", nil),
        ]
    )
    func nonTriggers(draft: String, caret: Int?) async {
        let menu = Self.menu()
        await menu.load()
        menu.update(draft: draft, caret: caret)
        #expect(menu.trigger == nil)
        #expect(!menu.isVisible)
    }

    @Test("游標在句子中間時以游標前那段判斷;開頭 / 後面還有字也是開頭選單")
    func caretInsideSentence() async {
        let menu = Self.menu()
        menu.update(draft: "先跑 /td 再幫我改", caret: 6)
        await menu.load()
        #expect(menu.trigger == SlashMenuModel.Trigger(range: 3..<6, query: "td", placement: .inline))
        #expect(menu.ranked?.map(\.name) == ["mattpocock-skills:tdd"])
        menu.update(draft: "/mo 其他文字", caret: 3)
        #expect(menu.trigger?.placement == .leading)
        #expect(menu.ranked?.map(\.name) == ["model"])
    }

    @Test("只有內建指令的 agent(固定清單)文中不出現;開頭照常列出")
    func inlineHiddenWithOnlyBuiltIns() async {
        let menu = Self.menu(SlashCatalog(fixed: [SlashCommand(name: "model", summary: "Choose the model")]))
        menu.update(draft: "hi /")
        await menu.load()
        #expect(!menu.isVisible)
        #expect(menu.handle(.down) == false)
        menu.update(draft: "/")
        #expect(menu.isVisible)
    }

    @Test("文中選單按 Esc 收起，直到離開這段 /字詞 才重新出現")
    func inlineEscapeUntilLeavingWord() async {
        let menu = Self.menu()
        menu.update(draft: "hi /")
        await menu.load()
        menu.handle(.dismiss)
        menu.update(draft: "hi /mat")
        #expect(!menu.isVisible)
        menu.update(draft: "hi /mat ")
        menu.update(draft: "hi /mat /")
        #expect(menu.isVisible)
    }

    @Test("選定時只把 /字詞 換成 /名稱 ,前後文字保留，游標停在插入文字之後")
    func fillReplacesOnlyTriggerWord() {
        let inline = SlashMenuModel.Trigger(range: 3..<6, query: "td", placement: .inline)
        let filled = inline.filling("mattpocock-skills:tdd", in: "先跑 /td 再幫我改")
        #expect(filled.draft == "先跑 /mattpocock-skills:tdd 再幫我改")
        #expect(filled.caret == 26)
        let leading = SlashMenuModel.Trigger(range: 0..<4, query: "rev", placement: .leading)
        let whole = leading.filling("review", in: "/rev")
        #expect(whole.draft == "/review ")
        #expect(whole.caret == 8)
    }

    @Test("游標後已經是空白或換行時不再補空格，游標停在既有空白之後")
    func fillReusesFollowingWhitespace() {
        let trigger = SlashMenuModel.Trigger(range: 3..<6, query: "td", placement: .inline)
        let spaced = trigger.filling("tdd", in: "先跑 /td 再改")
        #expect(spaced.draft == "先跑 /tdd 再改")
        #expect(spaced.caret == 8)
        let newline = trigger.filling("tdd", in: "先跑 /td\n再改")
        #expect(newline.draft == "先跑 /tdd\n再改")
        #expect(newline.caret == 8)
    }

    @Test("輸入名稱後改成單一排名清單：名稱開頭 > 名稱包含 > 說明包含;同級依分組與原順序")
    func searchRanksSingleList() async {
        let menu = SlashMenuModel(loader: {
            SlashCatalog(sections: [
                SlashSection(source: .builtIn, commands: [
                    SlashCommand(name: "clear", summary: "Clear the conversation history"),
                    SlashCommand(name: "model", argumentHint: "[model]", summary: "Choose the model"),
                    SlashCommand(name: "review", summary: "Review a pull request"),
                ]),
                SlashSection(source: .plugin("kit"), commands: [
                    SlashCommand(name: "kit:pre-review", summary: "Prepare a diff"),
                    SlashCommand(name: "kit:audit", summary: "Ask for a review of the plan"),
                    SlashCommand(name: "kit:revise", summary: "Revise the draft"),
                ]),
            ], isComplete: true)
        })
        menu.update(draft: "/")
        await menu.load()
        #expect(menu.ranked == nil)
        #expect(menu.sections.map(\.source) == [.builtIn, .plugin("kit")])

        menu.update(draft: "/REV")
        // 名稱開頭:review、kit:revise 不算(開頭是 kit:)→ 名稱包含：kit:pre-review、kit:revise → 說明包含:kit:audit。
        #expect(menu.ranked?.map(\.name) == ["review", "kit:pre-review", "kit:revise", "kit:audit"])
        #expect(menu.highlighted == "review")
        menu.update(draft: "/history")
        #expect(menu.ranked?.map(\.name) == ["clear"])
        menu.update(draft: "/zzz")
        #expect(menu.ranked == [])
    }

    @Test("鍵盤上下移動高亮(停在頭尾),Return 選取高亮的指令")
    func keyboardSelection() async {
        let menu = Self.menu()
        var picked: String?
        menu.onPick = { picked = $0.name }
        menu.update(draft: "/")
        await menu.load()
        #expect(menu.highlighted == "clear")
        #expect(menu.handle(.up) == true)
        #expect(menu.highlighted == "clear")
        menu.handle(.down)
        menu.handle(.down)
        #expect(menu.highlighted == "mattpocock-skills:implement")
        menu.handle(.down)
        menu.handle(.down)
        #expect(menu.highlighted == "mattpocock-skills:tdd")
        #expect(menu.handle(.select) == true)
        #expect(picked == "mattpocock-skills:tdd")
    }

    @Test("搜尋改變時高亮回到第一個符合的;選單沒出現時不攔按鍵")
    func highlightResetsOnSearch() async {
        let menu = Self.menu()
        menu.update(draft: "/")
        await menu.load()
        menu.handle(.down)
        menu.update(draft: "/mattpocock")
        #expect(menu.highlighted == "mattpocock-skills:implement")
        menu.update(draft: "plain text")
        #expect(menu.handle(.down) == false)
        #expect(menu.handle(.select) == false)
    }

    @Test("Esc 收起選單，直到草稿離開 slash 狀態再回來")
    func escapeDismisses() async {
        let menu = Self.menu()
        menu.update(draft: "/")
        await menu.load()
        #expect(menu.handle(.dismiss) == true)
        #expect(!menu.isVisible)
        menu.update(draft: "/m")
        #expect(!menu.isVisible)
        menu.update(draft: "")
        menu.update(draft: "/")
        #expect(menu.isVisible)
    }

    @Test("這種 agent 沒有選單(Pi／OMP)時不出現;清單不完整時照實標示")
    func noMenuAndIncomplete() async {
        let none = Self.menu(nil)
        none.update(draft: "/")
        await none.load()
        #expect(!none.isVisible)

        let partial = Self.menu(SlashCatalog(sections: Self.catalog.sections, isComplete: false))
        partial.update(draft: "/")
        await partial.load()
        #expect(partial.isVisible)
        #expect(partial.isIncomplete)
    }

    @Test("清單只載入一次")
    func loadsOnce() async {
        let counter = Counter()
        let menu = SlashMenuModel(loader: {
            await counter.increment()
            return Self.catalog
        })
        menu.update(draft: "/")
        await menu.load()
        await menu.load()
        #expect(await counter.value == 1)
    }


    /// 依序回不同結果的 loader 與可調的時鐘(測試預載、重試、重讀)。
    actor Script {
        var replies: [SlashCatalog?]
        var clock = Date(timeIntervalSince1970: 1_000)
        private(set) var calls = 0
        init(_ replies: [SlashCatalog?]) { self.replies = replies }
        func next() -> SlashCatalog? {
            calls += 1
            return replies.count > 1 ? replies.removeFirst() : replies[0]
        }
        func advance(_ seconds: TimeInterval) { clock += seconds }
        func now() -> Date { clock }
    }

    static func waitUntil(_ condition: @escaping () async -> Bool) async {
        for _ in 0..<200 where !(await condition()) { try? await Task.sleep(for: .milliseconds(10)) }
    }

    static let partialCatalog = SlashCatalog(sections: catalog.sections, isComplete: false)

    @Test("預載:不用打 / 就載入清單,文中指令上色立刻有名稱(#469)")
    func preloadWithoutTyping() async {
        let menu = SlashMenuModel(loader: { Self.catalog })
        menu.refreshIfNeeded()
        await menu.load()
        #expect(menu.inlineNames == ["mattpocock-skills:implement", "mattpocock-skills:tdd"])
        #expect(!menu.isVisible)
    }

    @Test("沒讀到或不完整就退避重讀(2、5、15 秒),讀完整就停")
    func retriesUntilComplete() async {
        let script = Script([nil, Self.partialCatalog, Self.catalog])
        let sleeper = RecordingSleeper(fires: { _ in true })
        let menu = SlashMenuModel(loader: { await script.next() }, sleep: sleeper.sleep, now: { Date() })
        menu.refreshIfNeeded()
        await menu.load()
        await Self.waitUntil { await script.calls == 3 }
        await Self.waitUntil { !menu.inlineNames.isEmpty }
        #expect(await script.calls == 3)
        #expect(await sleeper.requested == [.seconds(2), .seconds(5)])
        #expect(menu.inlineNames.contains("mattpocock-skills:tdd"))
        #expect(!menu.isIncomplete)
    }

    @Test("重讀失敗(沒讀到或變不完整)保留舊清單")
    func failedRefreshKeepsOldCatalog() async {
        let ticks = Ticks()
        let script = Script([Self.catalog, nil])
        let sleeper = RecordingSleeper(fires: { _ in false })
        let menu = SlashMenuModel(loader: { await script.next() }, sleep: sleeper.sleep, now: { ticks.read() })
        menu.refreshIfNeeded()
        await menu.load()
        ticks.advance(61)
        menu.refreshIfNeeded()
        await Self.waitUntil { await script.calls == 2 }
        #expect(await script.calls == 2)
        #expect(menu.inlineNames == ["mattpocock-skills:implement", "mattpocock-skills:tdd"])
    }

    @Test("超過 60 秒再觸發會背景重讀並換成新清單")
    func staleRefreshReplaces() async {
        let ticks = Ticks()
        let added = SlashCatalog(sections: Self.catalog.sections + [
            SlashSection(source: .plugin("new-kit"), commands: [SlashCommand(name: "new-kit:fresh", summary: "New")]),
        ], isComplete: true)
        let script = Script([Self.catalog, added])
        let menu = SlashMenuModel(loader: { await script.next() }, now: { ticks.read() })
        menu.refreshIfNeeded()
        await menu.load()
        ticks.advance(61)
        menu.refreshIfNeeded()
        #expect(!menu.isLoading, "重讀在背景,不顯示載入中")
        await Self.waitUntil { menu.inlineNames.contains("new-kit:fresh") }
        #expect(menu.inlineNames.contains("new-kit:fresh"))
    }

    @Test("載入中途標記過期(對話紀錄路徑才出現):這輪結束後立刻重讀,換成新結果(#472)")
    func markStaleWhileLoadingRereads() async {
        let gate = Gate()
        let added = SlashCatalog(sections: Self.catalog.sections + [
            SlashSection(source: .session, commands: [SlashCommand(name: "session-skill", summary: "S")]),
        ], isComplete: true)
        let script = Script([Self.catalog, added])
        let menu = SlashMenuModel(loader: {
            let result = await script.next()
            await gate.wait()
            return result
        })
        menu.refreshIfNeeded()
        await Self.waitUntil { await script.calls == 1 }
        #expect(menu.isLoading)
        menu.markStale()
        await gate.open()
        await menu.load()
        await Self.waitUntil { await script.calls == 2 }
        await Self.waitUntil { menu.inlineNames.contains("session-skill") }
        #expect(await script.calls == 2)
        #expect(menu.inlineNames.contains("session-skill"))
    }

    @Test("重試預算用完就停:輪詢一直呼叫 refreshIfNeeded 也不重開,打 / 或依據改變才再試(#472)")
    func retryBudgetStopsPollingLoop() async {
        let script = Script([nil])
        let sleeper = RecordingSleeper(fires: { _ in true })
        let menu = SlashMenuModel(loader: { await script.next() }, sleep: sleeper.sleep, now: { Date() })
        menu.refreshIfNeeded()
        await menu.load()
        await Self.waitUntil { await script.calls == 4 }
        #expect(await script.calls == 4, "首次一次加 2、5、15 秒三次重試")
        try? await Task.sleep(for: .milliseconds(100))
        for _ in 0..<5 {
            menu.refreshIfNeeded()
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(await script.calls == 4, "輪詢路徑不得重開重試")
        menu.update(draft: "/")
        await Self.waitUntil { await script.calls == 8 }
        #expect(await script.calls == 8, "使用者打 / 再試一輪")
        try? await Task.sleep(for: .milliseconds(100))
        menu.markStale()
        menu.refreshIfNeeded()
        await Self.waitUntil { await script.calls == 12 }
        #expect(await script.calls == 12, "依據改變重新有預算")
        menu.restartRetries()
        try? await Task.sleep(for: .milliseconds(100))
        menu.refreshIfNeeded()
        await Self.waitUntil { await script.calls == 16 }
        #expect(await script.calls == 16, "聊天重新開始也還原預算")
    }

    @Test("背景重讀進行中依據改變:這輪結果不算最新,馬上用新依據再讀一次(#472)")
    func markStaleDuringBackgroundReload() async {
        let gate = Gate()
        let session = SlashCatalog(sections: Self.catalog.sections + [
            SlashSection(source: .session, commands: [SlashCommand(name: "session-skill", summary: "S")]),
        ], isComplete: true)
        let script = Script([Self.partialCatalog, Self.catalog, session])
        let sleeper = RecordingSleeper(fires: { _ in true })
        let menu = SlashMenuModel(loader: {
            let calls = await script.calls
            let result = await script.next()
            if calls == 1 { await gate.wait() }
            return result
        }, sleep: sleeper.sleep, now: { Date() })
        menu.refreshIfNeeded()
        await menu.load()
        await Self.waitUntil { await script.calls == 2 }
        menu.markStale()
        await gate.open()
        await Self.waitUntil { menu.inlineNames.contains("session-skill") }
        #expect(await script.calls == 3)
        #expect(menu.inlineNames.contains("session-skill"))
    }

    @Test("聊天關掉就取消背景重讀,不再為看不到的畫面探索主機(#472)")
    func cancelBackgroundReloadStopsRetries() async {
        let gate = Gate()
        let script = Script([Self.partialCatalog])
        let sleeper = RecordingSleeper(fires: { _ in true })
        let menu = SlashMenuModel(loader: {
            let calls = await script.calls
            let result = await script.next()
            if calls == 1 { await gate.wait() }
            return result
        }, sleep: sleeper.sleep, now: { Date() })
        menu.refreshIfNeeded()
        await Self.waitUntil { await script.calls == 2 }
        menu.cancelBackgroundReload()
        await gate.open()
        try? await Task.sleep(for: .milliseconds(150))
        #expect(await script.calls == 2)
    }

    actor Gate {
        private var opened = false
        func open() { opened = true }
        func wait() async { while !opened { try? await Task.sleep(for: .milliseconds(5)) } }
    }

    final class Ticks: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_000)
        func read() -> Date { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
    }

    actor Counter {
        var value = 0
        func increment() { value += 1 }
    }
}
