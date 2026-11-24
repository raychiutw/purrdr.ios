import Foundation
import PurrdrAgentFeatures
import PurrdrCore

/// 聊天「⋯」選單的項目清單(#515):哪些項目出現、副標寫什麼、停用與原因,畫面只負責畫。
struct ConversationMoreMenuPlan: Equatable {
    enum Item: Hashable {
        case usage, permissionMode, model, sendWhenDone
        case todos, backgroundAgents
        case terminal, gitChanges, layout
    }

    struct Entry: Equatable, Identifiable {
        var item: Item
        var id: Item { item }
        var subtitle: String?
        /// 停用時的原因(同時是副標);可用時是 `nil`。
        var disabledReason: String?
        var isEnabled: Bool { disabledReason == nil }
    }

    struct Input: Equatable {
        var usageSummary: UsageSummary?
        var hasPermissionMode = false
        var permissionModeSubtitle: String?
        var hasModel = false
        var modelSubtitle: String?
        var hasSendWhenDone = false
        var queuedCount = 0
        var sendWhenDoneIsOn = false
        var todoDone = 0
        var todoTotal = 0
        var hasBackgroundAgents = false
        var runningBackgroundAgents = 0
        var isReadOnlyDevice = false
        var canOpenTerminal = false
        var canShowLayout = false
        var gitSubtitle: String?
        var gitIsEnabled = true
    }

    var groups: [[Entry]]

    init(_ input: Input) {
        let readOnly = input.isReadOnlyDevice ? String(localized: "Read-only device") : nil
        func entry(_ item: Item, _ subtitle: String?, disabledReason: String? = nil) -> Entry {
            Entry(item: item, subtitle: disabledReason ?? subtitle, disabledReason: disabledReason)
        }

        var first = [entry(.usage, input.usageSummary.map { "\($0.source.name) \($0.percent)%" })]
        if input.hasPermissionMode {
            first.append(entry(.permissionMode, input.permissionModeSubtitle, disabledReason: readOnly))
        }
        if input.hasModel {
            first.append(entry(.model, input.modelSubtitle, disabledReason: readOnly))
        }
        if input.hasSendWhenDone {
            let subtitle = input.queuedCount > 0
                ? String(localized: "\(input.queuedCount) queued")
                : input.sendWhenDoneIsOn ? String(localized: "On") : String(localized: "Off")
            first.append(entry(.sendWhenDone, subtitle, disabledReason: readOnly))
        }

        var second: [Entry] = []
        if input.todoTotal > 0 {
            second.append(entry(.todos, String(localized: "\(input.todoDone) of \(input.todoTotal) done")))
        }
        if input.hasBackgroundAgents {
            second.append(entry(.backgroundAgents, String(localized: "\(input.runningBackgroundAgents) running")))
        }

        var third: [Entry] = []
        if input.canOpenTerminal { third.append(entry(.terminal, String(localized: "This agent’s screen"))) }
        third.append(
            entry(.gitChanges, input.gitSubtitle, disabledReason: input.gitIsEnabled ? nil : input.gitSubtitle))
        if input.canShowLayout { third.append(entry(.layout, String(localized: "This tab’s pane layout"))) }

        groups = [first, second, third].filter { !$0.isEmpty }
    }
}
