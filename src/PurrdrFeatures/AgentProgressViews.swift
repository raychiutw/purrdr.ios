import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

extension AgentProgress.ContextLevel {
    /// 70% 起橙、85% 起紅;其餘是次要文字色。
    var style: AnyShapeStyle {
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
                    .stroke(level.style, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 13, height: 13)
            Text(verbatim: "\(percent)%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(level.style)
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

/// 聊天點標題升起的 sheet(#307):上方是 context 數字與條，下方是完整待辦清單(已完成打勾加刪除線、未完成空框、進行中綠框)。
struct AgentProgressSheet: View {
    let title: String
    let progress: AgentProgress
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let percent = progress.contextPercent {
                    Section("Context") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(verbatim: "\(percent)%")
                                .font(.largeTitle.weight(.semibold).monospacedDigit())
                                .foregroundStyle(progress.contextLevel.style)
                            ProgressView(value: Double(min(max(percent, 0), 100)), total: 100)
                                .tint(progress.contextLevel == .normal ? nil : progress.contextLevel == .warning ? Color.orange : Color.red)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text("Context \(percent)%"))
                        .accessibilityIdentifier("progress.context")
                    }
                }
                if !progress.todos.isEmpty {
                    Section {
                        ForEach(Array(progress.todos.enumerated()), id: \.offset) { _, todo in
                            TodoRow(todo: todo)
                        }
                    } header: {
                        Text("Todos \(progress.todoDone)/\(progress.todoTotal)")
                    }
                }
            }
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("progress.sheet")
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
