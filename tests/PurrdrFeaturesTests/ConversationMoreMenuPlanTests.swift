import Foundation
import PurrdrCore
@testable import PurrdrFeatures
import Testing

/// 聊天「⋯」選單的項目與分組(#515):出現條件、副標、停用原因、沒資料不列。
@Suite("聊天更多選單項目")
struct ConversationMoreMenuPlanTests {
    static func full() -> ConversationMoreMenuPlan.Input {
        var input = ConversationMoreMenuPlan.Input()
        input.usageSummary = UsageSummary(source: .weekly, percent: 93, display: .used, level: .critical)
        input.hasPermissionMode = true
        input.permissionModeSubtitle = "Bypass Permissions"
        input.hasModel = true
        input.modelSubtitle = "Sonnet 5.5 · Medium"
        input.hasSendWhenDone = true
        input.queuedCount = 1
        input.todoDone = 3
        input.todoTotal = 7
        input.hasBackgroundAgents = true
        input.runningBackgroundAgents = 1
        input.canOpenTerminal = true
        input.canShowLayout = true
        input.gitSubtitle = "main · 3 files"
        return input
    }

    static func items(_ input: ConversationMoreMenuPlan.Input) -> [[ConversationMoreMenuPlan.Item]] {
        ConversationMoreMenuPlan(input).groups.map { $0.map(\.item) }
    }

    static func entry(_ item: ConversationMoreMenuPlan.Item, _ input: ConversationMoreMenuPlan.Input) -> ConversationMoreMenuPlan.Entry? {
        ConversationMoreMenuPlan(input).groups.flatMap { $0 }.first { $0.item == item }
    }

    @Test("三段:用量、權限、模型、做完再送;待辦、背景子 Agent;終端機、Git、版面")
    func threeGroups() {
        #expect(
            Self.items(Self.full()) == [
                [.usage, .permissionMode, .model, .sendWhenDone],
                [.todos, .backgroundAgents],
                [.terminal, .gitChanges, .layout],
            ])
    }

    @Test("沒有待辦與背景子 Agent 時第二段整段不列")
    func emptySecondGroupDropped() {
        var input = Self.full()
        input.todoTotal = 0
        input.hasBackgroundAgents = false
        #expect(Self.items(input) == [[.usage, .permissionMode, .model, .sendWhenDone], [.terminal, .gitChanges, .layout]])
        input.todoTotal = 2
        #expect(Self.items(input)[1] == [.todos])
    }

    @Test("沒有權限模式、模型、做完再送、終端機、版面時各自不列;用量與 Git 一律在")
    func optionalItems() {
        var input = ConversationMoreMenuPlan.Input()
        input.gitSubtitle = "Not a Git folder"
        input.gitIsEnabled = false
        #expect(Self.items(input) == [[.usage], [.gitChanges]])
    }

    @Test("副標:用量是最需要注意的一項,權限與模型是目前值,待辦與子 Agent 是進度")
    func subtitles() {
        let input = Self.full()
        #expect(Self.entry(.usage, input)?.subtitle == "Weekly Limit 93%")
        #expect(Self.entry(.permissionMode, input)?.subtitle == "Bypass Permissions")
        #expect(Self.entry(.model, input)?.subtitle == "Sonnet 5.5 · Medium")
        #expect(Self.entry(.sendWhenDone, input)?.subtitle == "1 queued")
        #expect(Self.entry(.todos, input)?.subtitle == "3 of 7 done")
        #expect(Self.entry(.backgroundAgents, input)?.subtitle == "1 running")
        #expect(Self.entry(.gitChanges, input)?.subtitle == "main · 3 files")
    }

    @Test("用量項目沒有資料時沒有副標;做完再送沒排時看開關")
    func subtitleFallbacks() {
        var input = Self.full()
        input.usageSummary = nil
        input.queuedCount = 0
        #expect(Self.entry(.usage, input)?.subtitle == nil)
        #expect(Self.entry(.sendWhenDone, input)?.subtitle == "Off")
        input.sendWhenDoneIsOn = true
        #expect(Self.entry(.sendWhenDone, input)?.subtitle == "On")
    }

    @Test("唯讀裝置:權限模式、模型、做完再送停用並說明;用量、待辦等仍可開")
    func readOnlyDevice() {
        var input = Self.full()
        input.isReadOnlyDevice = true
        for item in [ConversationMoreMenuPlan.Item.permissionMode, .model, .sendWhenDone] {
            let entry = Self.entry(item, input)
            #expect(entry?.isEnabled == false)
            #expect(entry?.disabledReason == "Read-only device")
            #expect(entry?.subtitle == "Read-only device")
        }
        for item in [ConversationMoreMenuPlan.Item.usage, .todos, .backgroundAgents, .terminal, .layout] {
            #expect(Self.entry(item, input)?.isEnabled == true)
        }
    }

    @Test("Git 不可用時停用,原因就是副標")
    func gitDisabled() {
        var input = Self.full()
        input.gitSubtitle = "Not a Git folder"
        input.gitIsEnabled = false
        let git = Self.entry(.gitChanges, input)
        #expect(git?.isEnabled == false)
        #expect(git?.subtitle == "Not a Git folder")
    }
}
