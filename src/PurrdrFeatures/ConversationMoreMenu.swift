import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 對話畫面右上角的「更多」選單(#381、#515):三段——用量與 Context、權限模式、模型與思考深度、做完再送;
/// 待辦、背景子 Agent(沒有資料時不列);Pane 終端機、Git 變更、顯示版面。
///
/// 項目、副標與停用原因由 `ConversationMoreMenuPlan` 決定,這裡只畫;點項目交給 `select`(開各自的 sheet 或畫面,
/// 選項不直接放在選單裡,照 DESIGN「選擇控制」)。系統 `Menu`(勾在前、圖示在後)。
struct ConversationMoreMenu: View {
    /// 聊天狀態在這個 view 內才讀:輪詢造成的變動只重畫選單,不讓整個畫面的工具列重建(重建會把開著的選單收起來)。
    let model: ConversationModel
    let usageSummary: UsageSummary?
    let canOpenTerminal: Bool
    let canShowLayout: Bool
    let select: (ConversationMoreMenuPlan.Item) -> Void

    var body: some View {
        let plan = ConversationMoreMenuPlan(
            model.moreMenuInput(usageSummary: usageSummary, canOpenTerminal: canOpenTerminal, canShowLayout: canShowLayout))
        Menu {
            ForEach(Array(plan.groups.enumerated()), id: \.offset) { _, group in
                Section {
                    ForEach(group) { entry in
                        Button { select(entry.item) } label: {
                            item(entry)
                        }
                        .disabled(!entry.isEnabled)
                        .accessibilityIdentifier(entry.item.identifier)
                    }
                }
            }
        } label: {
            Label("More", systemImage: "ellipsis")
                .labelStyle(.iconOnly)
        }
        .frame(minWidth: 44, minHeight: 44)    // 觸控範圍 ≥ 44pt
        .accessibilityIdentifier("conversation.more")
    }

    @ViewBuilder
    private func item(_ entry: ConversationMoreMenuPlan.Entry) -> some View {
        // 系統選單的項目用「標題 Text、副標 Text、Image」三個子視圖排成標題＋副標＋圖示。
        Text(entry.item.title)
        if let subtitle = entry.subtitle {
            Text(verbatim: subtitle)
        }
        Image(systemName: entry.item.symbol)
    }
}

extension ConversationMoreMenuPlan.Item {
    var title: LocalizedStringKey {
        switch self {
        case .usage: "Usage & Context"
        case .permissionMode: "Permission Mode"
        case .model: "Model & Effort"
        case .sendWhenDone: "Send When Done"
        case .todos: "Todos"
        case .backgroundAgents: "Background Agents"
        case .terminal: "Pane Terminal"
        case .gitChanges: "Git Changes"
        case .layout: "Show Layout"
        }
    }

    var symbol: String {
        switch self {
        case .usage: "gauge.with.dots.needle.50percent"
        case .permissionMode: "checkmark.shield"
        case .model: "cpu"
        case .sendWhenDone: "hourglass"
        case .todos: "checklist"
        case .backgroundAgents: "person.2"
        case .terminal: "apple.terminal"
        case .gitChanges: "arrow.triangle.branch"
        case .layout: "rectangle.split.2x2"
        }
    }

    var identifier: String {
        switch self {
        case .usage: "menu.usage"
        case .permissionMode: "menu.permissionMode"
        case .model: "menu.model"
        case .sendWhenDone: "menu.sendWhenDone"
        case .todos: "menu.todos"
        case .backgroundAgents: "menu.backgroundAgents"
        case .terminal: "terminal.open"
        case .gitChanges: "changes.open"
        case .layout: "layout.show"
        }
    }
}
