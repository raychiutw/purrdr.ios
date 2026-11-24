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
    /// 設計稿(#502):環 18pt、數字 13pt;環隨字級放大。
    @ScaledMetric(relativeTo: .footnote) private var ringSize: CGFloat = 18

    private var level: AgentProgress.ContextLevel { AgentProgress(contextPercent: percent).contextLevel }

    var body: some View {
        HStack(spacing: 4) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 2.6)
                Circle()
                    .trim(from: 0, to: CGFloat(min(max(percent, 0), 100)) / 100)
                    .stroke(level.tint, style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: ringSize, height: ringSize)
            Text(verbatim: "\(percent)%")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondaryText)
        }
        .accessibilityHidden(true)
        .accessibilityIdentifier("agent.row.context")
    }
}

struct TodoRow: View {
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
