import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

extension AgentProgress.ContextLevel {
    /// 圓環與進度條的顏色(唯一對應):與方案用量同一組低飽和級距(#389)——正常綠、70% 起棕橘、85% 起紅。
    /// 只用在圖形;百分比文字維持一般文字色(DESIGN.md「狀態色」:顏色只上符號與圓點)。
    var tint: AnyShapeStyle {
        switch self {
        case .normal: AnyShapeStyle(AccessibleColors.planUsageAmple.color)
        case .warning: AnyShapeStyle(AccessibleColors.planUsageLow.color)
        case .critical: AnyShapeStyle(AccessibleColors.planUsageDepleted.color)
        }
    }
}

/// 列表右欄時間下方的 context 小圓環與百分比(#307)。數字與顏色並用，不只靠顏色。
struct ContextMeter: View {
    let percent: Int

    private var level: AgentProgress.ContextLevel { AgentProgress(contextPercent: percent).contextLevel }

    var body: some View {
        HStack(spacing: 4) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: CGFloat(min(max(percent, 0), 100)) / 100)
                    .stroke(level.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 13, height: 13)
            Text(verbatim: "\(percent)%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondaryText)
        }
        .accessibilityHidden(true)
        .accessibilityIdentifier("agent.row.context")
    }
}

/// 第二行尾的「☑ 3/7」(對 VoiceOver 隱藏，念在整列句子裡)。
struct TodoCount: View {
    let done: Int
    let total: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "checkmark.square")
            Text(verbatim: "\(done)/\(total)").monospacedDigit()
        }
        .font(.footnote)
        .foregroundStyle(.secondaryText)
        .fixedSize()
        .accessibilityHidden(true)
        .accessibilityIdentifier("agent.row.todos")
    }
}

/// 聊天點標題膠囊升起的面板(#380,原型 Header／PanelStates):上方 context,接著模型、待辦、背景子 Agent、做完再送,
/// 下方是權限模式選項(直接展開、可切換)。這些資訊只在這裡出現(膠囊第二行只有狀態、主機與非一般的權限模式)。
struct ConversationStatusSheet: View {
    let title: String
    let model: ConversationModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.usageSections) private var usage
    @Environment(\.usageHost) private var usageHost
    @State private var isChoosingModel = false

    var body: some View {
        let sheet = model.statusSummary.sheet
        NavigationStack {
            List {
                usageSection
                contextSection(sheet)
                Section {
                    if model.supportsPermissionMode {
                        modelRow
                    } else if model.readsStatusLine, let summary = model.modelSummary {
                        // 只顯示(Antigravity 的模型要在電腦的終端機切換)。
                        PanelValueRow(title: "Model", value: summary)
                            .accessibilityIdentifier("status.model")
                    }
                    if !sheet.progress.todos.isEmpty {
                        NavigationLink {
                            TodoListPage(progress: sheet.progress)
                        } label: {
                            PanelValueRow(title: "Todos", value: "\(sheet.progress.todoDone) / \(sheet.progress.todoTotal)")
                        }
                        .accessibilityIdentifier("status.todos")
                    }
                    if let pane = sheet.backgroundAgents, !pane.rows.isEmpty {
                        NavigationLink {
                            BackgroundAgentsPage(model: model, pane: pane)
                        } label: {
                            PanelValueRow(
                                title: "Background Agents",
                                value: String(localized: "\(pane.rows.filter { $0.state == .running }.count) running"))
                        }
                        .accessibilityIdentifier("status.backgroundAgents")
                    }
                    if sheet.hasSendWhenDone, let sendWhenDone = model.sendWhenDone {
                        SendWhenDoneToggle(model: sendWhenDone)
                    }
                } footer: {
                    if model.isReadOnly, sheet.hasSendWhenDone {
                        Text("This device is paired read-only, so it can’t queue messages.")
                    }
                }
                if model.supportsPermissionMode {
                    PermissionModeSection(model: model)
                } else if let policy = model.approvalPolicy {
                    ApprovalPolicySection(policy: policy)
                } else if model.readsStatusLine, let mode = model.permissionMode {
                    ReadOnlyPermissionModeSection(mode: mode)
                }
                if !model.supportsPermissionMode, model.approvalPolicy == nil, !(model.readsStatusLine && model.permissionMode != nil), sheet.progress.isEmpty, sheet.backgroundAgents?.rows.isEmpty ?? true, !sheet.hasSendWhenDone {
                    Text("Nothing to show yet.")
                        .foregroundStyle(.secondaryText)
                        .accessibilityIdentifier("status.empty")
                }
            }
            .appGroupedList()
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { SheetCloseToolbar() }
            .navigationDestination(for: DelegationRoute.self) { route in
                DelegationDestination(route: route, conversation: model)
            }
            .sheet(isPresented: $isChoosingModel, onDismiss: { Task { await model.finishChoosingModel() } }) {
                ModelSheet(model: model)
            }
        }
        // 權限模式選項在最下面,一開始就攤開到底才看得到(原型 Header 是一整張面板)。
        .presentationDetents([.large])
        .accessibilityIdentifier("status.sheet")
    }

    /// 用量區(#389):這個 Agent 的 5 小時與 7 天,標題寫明範圍。沒有用量來源的 Agent 種類(Gemini 等)不顯示。
    @ViewBuilder
    private var usageSection: some View {
        if let usage, let usageHost, let agent = PlanUsageAgent(agentKind: model.agentKind) {
            UsageSectionContainer(host: usageHost, agents: [agent], context: usage, scopedTitle: true)
        }
    }

    @ViewBuilder
    private func contextSection(_ sheet: ConversationStatusSummary.Sheet) -> some View {
        if let percent = sheet.progress.contextPercent {
            Section {
                ContextUsageRow(
                    percent: percent, level: sheet.progress.contextLevel, display: usage?.display.display ?? .used)
            }
        }
    }

    /// 「模型 Opus 5.5 · 中 ›」:點了開模型選擇 sheet。
    private var modelRow: some View {
        Button {
            isChoosingModel = true
            Task { await model.beginChoosingModel() }
        } label: {
            HStack {
                PanelValueRow(title: "Model", value: model.modelSummary ?? "")
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!model.canChooseModel)
        .accessibilityHint(Text("Opens the list of models."))
        .accessibilityIdentifier("status.model")
    }
}

/// 面板的一列:左標題、右次要色的值。
private struct PanelValueRow: View {
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 8)
            Text(verbatim: value)
                .foregroundStyle(.secondaryText)
                .lineLimit(1)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}

private struct TodoListPage: View {
    let progress: AgentProgress

    var body: some View {
        List {
            ForEach(Array(progress.todos.enumerated()), id: \.offset) { _, todo in
                TodoRow(todo: todo)
            }
        }
        .appGroupedList()
        .navigationTitle(Text("Todos \(progress.todoDone)/\(progress.todoTotal)"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

private struct BackgroundAgentsPage: View {
    let model: ConversationModel
    let pane: AgentsPane

    var body: some View {
        List {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let since = model.agentsPaneReadAt.map { max(0, context.date.timeIntervalSince($0)) } ?? 0
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(pane.rows) { row in
                        if let card = model.subagentCard(forTask: row.task), model.canOpen(card) {
                            NavigationLink(value: DelegationRoute.subagent(card)) {
                                AgentsBarRow(row: row, since: since)
                            }
                        } else {
                            AgentsBarRow(row: row, since: since)
                        }
                    }
                }
            }
        }
        .appGroupedList()
        .navigationTitle("Background Agents")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

private struct TodoRow: View {
    let todo: AgentProgress.Todo

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            switch todo.status {
            case .completed:
                Image(systemName: "checkmark.square.fill").foregroundStyle(.secondaryText)
            case .inProgress:
                Image(systemName: "square").foregroundStyle(.tint)
            case .pending:
                Image(systemName: "square").foregroundStyle(.secondaryText)
            }
            Text(todo.text)
                .strikethrough(todo.status == .completed)
                .foregroundStyle(todo.status == .completed ? AnyShapeStyle(.secondaryText) : AnyShapeStyle(.primary))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(todo.text), \(statusText)"))
    }

    private var statusText: String {
        switch todo.status {
        case .completed: String(localized: "Completed")
        case .inProgress: String(localized: "In progress")
        case .pending: String(localized: "Not started")
        }
    }
}
