import PurrdrCore
import SwiftUI

/// Agent 列表(DESIGN.md 方向 A):系統 grouped list,依「需要你／工作中／閒置」分 section。
public struct AgentListView: View {
    let model: AgentListModel

    public init(model: AgentListModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle("Agents")
        }
        .task { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading where model.sections.isEmpty:
            ProgressView("Loading agents…")
        case .failed(let message) where model.sections.isEmpty:
            ContentUnavailableView {
                Label("Can’t Load Agents", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await model.load() } }
            }
        default:
            List {
                ForEach(model.sections) { section in
                    Section(section.group.title) {
                        ForEach(section.rows) { AgentRowView(row: $0) }
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
        }
    }
}

struct AgentRowView: View {
    let row: AgentRow

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                titles
                Spacer(minLength: 8)
                StatusLabel(status: row.status)
            }
            // AX 字級放不下時改成上下堆疊，不截斷。
            VStack(alignment: .leading, spacing: 4) {
                titles
                StatusLabel(status: row.status)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("agent.row.\(row.id)")
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.title)
                .font(.body)
            Text(row.subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

/// Agent 狀態同時用文字、符號形狀與顏色表示，不只靠顏色(DESIGN.md)。
struct StatusLabel: View {
    let status: AgentStatus

    var body: some View {
        Label(status.title, systemImage: status.symbol)
            .font(.subheadline)
            .foregroundStyle(status == .blocked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
    }
}

extension AgentGroup {
    var title: LocalizedStringKey {
        switch self {
        case .needsYou: "Needs You"
        case .working: "Working"
        case .idle: "Idle"
        }
    }
}

extension AgentStatus {
    var title: LocalizedStringKey {
        switch self {
        case .blocked: "Needs You"
        case .working: "Working"
        case .done: "Done"
        case .idle: "Idle"
        case .unknown: "Unknown"
        }
    }

    /// 「需要你」一律有 `!` 符號(DESIGN.md 顏色一節)。
    var symbol: String {
        switch self {
        case .blocked: "exclamationmark.circle.fill"
        case .working: "ellipsis.circle"
        case .done: "checkmark.circle"
        case .idle: "pause.circle"
        case .unknown: "questionmark.circle"
        }
    }
}
