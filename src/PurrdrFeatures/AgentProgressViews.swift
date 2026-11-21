import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

extension AgentProgress.ContextLevel {
    /// 圓環與進度條的顏色(唯一對應):70% 起橙、85% 起紅;其餘是次要文字色。
    /// 只用在圖形;百分比文字維持一般文字色(DESIGN.md「狀態色」:顏色只上符號與圓點)。
    var tint: AnyShapeStyle {
        switch self {
        case .normal: AnyShapeStyle(.secondaryText)
        case .warning: AnyShapeStyle(Color.orange)
        case .critical: AnyShapeStyle(Color.red)
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

/// 聊天點標題升起的狀態 sheet(#307、#349):context 數字與條、完整待辦清單(已完成打勾加刪除線、未完成空框、進行中綠框)、
/// 背景子 Agent 清單與「做完再送」開關。這些資訊只在這裡出現(頂列只有 context 百分比，工作中膠囊只帶子 Agent 數)。
struct ConversationStatusSheet: View {
    let title: String
    let model: ConversationModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let sheet = model.statusSummary.sheet
        NavigationStack {
            List {
                if let percent = sheet.progress.contextPercent {
                    Section("Context") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(verbatim: "\(percent)%")
                                .font(.largeTitle.weight(.semibold).monospacedDigit())
                            ProgressView(value: Double(min(max(percent, 0), 100)), total: 100)
                                .tint(sheet.progress.contextLevel.tint)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text("Context \(percent)%"))
                        .accessibilityIdentifier("progress.context")
                    }
                }
                if !sheet.progress.todos.isEmpty {
                    Section {
                        ForEach(Array(sheet.progress.todos.enumerated()), id: \.offset) { _, todo in
                            TodoRow(todo: todo)
                        }
                    } header: {
                        Text("Todos \(sheet.progress.todoDone)/\(sheet.progress.todoTotal)")
                    }
                }
                if let pane = sheet.backgroundAgents, !pane.rows.isEmpty {
                    Section("Background Agents") {
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
                        .accessibilityIdentifier("status.backgroundAgents")
                    }
                }
                if sheet.hasSendWhenDone, let sendWhenDone = model.sendWhenDone {
                    Section {
                        SendWhenDoneToggle(model: sendWhenDone)
                    }
                }
                if sheet.progress.isEmpty, sheet.backgroundAgents?.rows.isEmpty ?? true, !sheet.hasSendWhenDone {
                    Text("Nothing to show yet.")
                        .foregroundStyle(.secondaryText)
                        .accessibilityIdentifier("status.empty")
                }
            }
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .navigationDestination(for: DelegationRoute.self) { route in
                DelegationDestination(route: route, conversation: model)
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("status.sheet")
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
