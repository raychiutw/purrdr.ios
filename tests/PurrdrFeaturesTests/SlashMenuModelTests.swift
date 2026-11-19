import Foundation
import PurrdrAgentFeatures
import PurrdrCore
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

    actor Counter {
        var value = 0
        func increment() { value += 1 }
    }
}
