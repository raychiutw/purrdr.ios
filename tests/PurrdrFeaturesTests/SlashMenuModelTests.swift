import Foundation
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

    @Test("草稿恰好是 / 加名稱字元時才出現;有空白或其他文字就收起")
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
        menu.update(draft: "x /model")
        #expect(!menu.isVisible)
        menu.update(draft: "/mattpocock-skills:t")
        #expect(menu.isVisible)
    }

    @Test("搜尋：名稱或說明包含輸入的字(不分大小寫),保留分組、空的分組拿掉")
    func searchFiltersWithinSections() async {
        let menu = Self.menu()
        menu.update(draft: "/")
        await menu.load()
        menu.update(draft: "/TDD")
        #expect(menu.sections == [SlashSection(source: .plugin("mattpocock-skills"), commands: [
            SlashCommand(name: "mattpocock-skills:tdd", summary: "Test-driven development"),
        ])])
        menu.update(draft: "/history")
        #expect(menu.sections.flatMap(\.commands).map(\.name) == ["clear"])
        menu.update(draft: "/zzz")
        #expect(menu.sections.isEmpty)
    }

    @Test("鍵盤上下移動高亮(停在頭尾),Return 選取：草稿變成 `/名稱 `、選單收起")
    func keyboardSelection() async {
        let menu = Self.menu()
        var picked: String?
        menu.onPick = { picked = $0 }
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
        #expect(picked == "/mattpocock-skills:tdd ")
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
