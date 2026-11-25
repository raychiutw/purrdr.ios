import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 「⋯」選單點開的 sheet(#515):權限模式、做完再送、待辦、背景子 Agent。用量用 `ConversationUsageSheet`,模型與思考深度用 `ModelSheet`(同輸入框的模型膠囊)。
///
/// 每個 sheet 的**內容**是可單獨嵌入的 view(`…ContentView`,不含 NavigationStack、關閉鈕與 toolbar);
/// sheet(`ConversationMenuSheet`)只是容器,聊天面板(#617)放同一批內容。
enum ConversationMenuSheetKind: String, Identifiable {
    case permissionMode, sendWhenDone, todos, backgroundAgents
    var id: String { rawValue }
}

/// 權限模式內容:勾選列(Claude)或只顯示的核准政策(Codex)。切換成功呼叫 `onSwitched`(sheet 據此自動關閉)。
struct PermissionModeContentView: View {
    let model: ConversationModel
    var onSwitched: (() -> Void)?

    var body: some View {
        List { PermissionModeSections(model: model, onSwitched: onSwitched) }
            .appGroupedList()
    }
}

/// 權限模式的 List 內容(不含 List 本身):sheet 與聊天面板(#617)共用。
struct PermissionModeSections: View {
    let model: ConversationModel
    var onSwitched: (() -> Void)?

    var body: some View {
        if model.supportsPermissionMode {
            PermissionModeSection(model: model, onSwitched: onSwitched)
        } else if let policy = model.approvalPolicy {
            ApprovalPolicySection(policy: policy)
        }
    }
}

/// 做完再送內容:開關與說明。
struct SendWhenDoneContentView: View {
    let model: ConversationModel

    var body: some View {
        List { SendWhenDoneSections(model: model) }
            .appGroupedList()
    }
}

/// 做完再送的 List 內容(不含 List 本身):sheet 與聊天面板(#617)共用;面板帶標題。
struct SendWhenDoneSections: View {
    let model: ConversationModel
    var showsHeader = false

    var body: some View {
        if let sendWhenDone = model.sendWhenDone {
            Section {
                SendWhenDoneToggle(model: sendWhenDone)
            } header: {
                if showsHeader { Text("Send When Done") }
            } footer: {
                if let reason = sendWhenDone.availability.unavailabilityReason {
                    // 不能用的原因直接寫在開關下方,不跳 alert(#626)。
                    Text(reason)
                        .accessibilityIdentifier("status.sendWhenDone.reason")
                } else if model.isReadOnly {
                    Text("This device is paired read-only, so it can’t queue messages.")
                } else {
                    Text("Queues your message and sends it when the agent is done.")
                }
            }
        }
    }
}

/// 待辦內容。
struct TodosContentView: View {
    let progress: AgentProgress

    var body: some View {
        List { TodoRows(progress: progress) }
            .appGroupedList()
            .accessibilityIdentifier("status.todos")
    }
}

/// 待辦列(不含 List 本身):sheet 與聊天面板(#617)共用。
struct TodoRows: View {
    let progress: AgentProgress

    var body: some View {
        ForEach(Array(progress.todos.enumerated()), id: \.offset) { _, todo in
            TodoRow(todo: todo)
        }
    }
}

/// 背景子 Agent 內容;點列推入 Subagent 畫面(容器要有 NavigationStack 與 `DelegationRoute` 的目的地)。
struct BackgroundAgentsContentView: View {
    let model: ConversationModel
    let pane: AgentsPane

    var body: some View {
        List { BackgroundAgentRows(model: model, pane: pane) }
            .appGroupedList()
            .accessibilityIdentifier("status.backgroundAgents")
    }
}

/// 背景子 Agent 列(不含 List 本身):sheet 與聊天面板(#617)共用。
struct BackgroundAgentRows: View {
    let model: ConversationModel
    let pane: AgentsPane

    var body: some View {
        // 每秒只重畫經過時間那一行(`AgentsBarRow` 自己的 TimelineView),不再整頁重建(#498)。
        ForEach(pane.rows) { row in
            if let card = model.subagentCard(forTask: row.task), model.canOpen(card) {
                NavigationLink(value: DelegationRoute.subagent(card)) {
                    AgentsBarRow(row: row, readAt: model.agentsPaneReadAt)
                }
            } else {
                AgentsBarRow(row: row, readAt: model.agentsPaneReadAt)
            }
        }
    }
}

/// 一個選單項目的 sheet 容器:NavigationStack、標題、左上 X 關閉。
struct ConversationMenuSheet: View {
    let kind: ConversationMenuSheetKind
    let model: ConversationModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar { SheetCloseToolbar() }
                .navigationDestination(for: DelegationRoute.self) { route in
                    DelegationDestination(route: route, conversation: model)
                }
        }
        .appSheet(detents: kind == .permissionMode || kind == .sendWhenDone ? [.medium, .large] : [.large])
        .accessibilityIdentifier("menu.sheet.\(kind.rawValue)")
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .permissionMode:
            PermissionModeContentView(model: model) { dismiss() }
        case .sendWhenDone:
            SendWhenDoneContentView(model: model)
        case .todos:
            let progress = model.statusSummary.sheet.progress
            TodosContentView(progress: progress)
        case .backgroundAgents:
            if let pane = model.statusSummary.sheet.backgroundAgents {
                BackgroundAgentsContentView(model: model, pane: pane)
            }
        }
    }

    private var title: LocalizedStringKey {
        switch kind {
        case .permissionMode: "Permission Mode"
        case .sendWhenDone: "Send When Done"
        case .todos: "Todos"
        case .backgroundAgents: "Background Agents"
        }
    }
}

extension ConversationModel {
    /// 「⋯」選單的輸入(#515):把聊天狀態換成純值,項目與副標的規則在 `ConversationMoreMenuPlan`。
    func moreMenuInput(
        usageSummary: UsageSummary?, canOpenTerminal: Bool, canShowLayout: Bool
    ) -> ConversationMoreMenuPlan.Input {
        var input = ConversationMoreMenuPlan.Input()
        input.usageSummary = usageSummary
        if supportsPermissionMode {
            input.hasPermissionMode = true
            input.permissionModeSubtitle = (switchingPermissionMode ?? permissionMode ?? .normal).displayName
        } else if let policy = approvalPolicy {
            input.hasPermissionMode = true
            input.permissionModeSubtitle = ApprovalPolicySection.displayName(of: policy)
        }
        if showsModelCapsule {
            input.hasModel = true
            input.modelSubtitle = modelSummary
        }
        let sheet = statusSummary.sheet
        if sheet.hasSendWhenDone, let sendWhenDone {
            input.hasSendWhenDone = true
            input.queuedCount = sendWhenDone.items.count
            input.sendWhenDoneIsOn = sendWhenDone.isEnabled
        }
        input.todoDone = sheet.progress.todoDone
        input.todoTotal = sheet.progress.todoTotal
        if let pane = sheet.backgroundAgents, !pane.rows.isEmpty {
            input.hasBackgroundAgents = true
            input.runningBackgroundAgents = pane.rows.filter { $0.state == .running }.count
        }
        input.isReadOnlyDevice = isReadOnly
        input.canOpenTerminal = canOpenTerminal
        input.canShowLayout = canShowLayout
        input.gitSubtitle = gitSubtitle
        input.gitIsEnabled = gitMenu.isEnabled && canOpenChanges
        return input
    }

    /// Git 變更的副標:可用時是「分支 · N 個檔案」,不可用時是原因。
    private var gitSubtitle: String {
        switch gitMenu {
        case .checking:
            canOpenChanges ? String(localized: "This agent’s working folder") : String(localized: "Folder unknown")
        case .available(let branch, let count):
            if let branch { String(localized: "\(branch) · \(count) files") } else { String(localized: "\(count) files") }
        case .unavailable(let reason):
            switch reason {
            case .unsupported: String(localized: "Not available on this host")
            case .notGitRepository: String(localized: "Not a Git folder")
            case .gitNotInstalled: String(localized: "Git isn’t installed on the host")
            case .agentMoved: String(localized: "The agent moved to another folder")
            case .hostServiceUpdateRequired: String(localized: "Update the host service")
            }
        }
    }
}
