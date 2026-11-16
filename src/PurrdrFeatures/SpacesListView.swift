import PurrdrCore
import SwiftUI

/// Spaces 檢視的 section(#40):單一 agent 的 workspace 是聊天列，其他是 workspace 卡片，下方內縮列出 Agent 與終端機列。
///
/// 終端機列跟 Agent 列一樣以 `ChatRoute`(主機 + pane id)導覽:pane 不是 agent 時開的是 Pane 終端機，
/// 所以 iPad 的 split view 選取與 iPhone 的推入都不用另外處理。
struct SpacesSectionsContent<AgentRowContent: View>: View {
    let sections: [SpacesSection]
    let model: MergedAgentListModel
    let presentation: WorkspacePresentation
    /// 跟 Agents 檢視同一種列(同樣的滑動、選單、已讀與釘選)。
    @ViewBuilder let agentRow: (AgentRow) -> AgentRowContent

    var body: some View {
        ForEach(sections) { section in
            Section {
                ForEach(section.items) { item in
                    switch item {
                    case .chat(let row):
                        agentRow(row)
                    case .card(let card):
                        WorkspaceCardHeader(card: card) { showLayout(card) }
                        ForEach(card.groups) { group in
                            if let title = group.title {
                                TabGroupTitle(title: title)
                            }
                            ForEach(group.rows) { row in
                                switch row {
                                case .agent(let row):
                                    agentRow(row).cardRail()
                                case .terminal(let row):
                                    NavigationLink(value: row.route) {
                                        TerminalRowView(row: row)
                                    }
                                    .accessibilityIdentifier("terminal.row.\(row.id)")
                                    .cardRail()
                                }
                            }
                        }
                    }
                }
            } header: {
                // 數量是這組顯示的項目數(卡片或列),跟 Agents 檢視一樣數畫面上的項目。
                AgentSectionHeader(group: section.group, count: section.count)
            }
        }
    }

    /// 點卡片本身或版面圖按鈕：開版面圖。顯示開啟當下的 snapshot,不即時更新(行為規格 F4)。
    private func showLayout(_ card: WorkspaceCard) {
        let layout = model.snapshot(for: card.host).flatMap { SpacesLayout(snapshot: $0, workspaceID: card.workspaceID) }
        presentation.host = card.host
        presentation.sheet = .layout(workspaceLabel: card.label, layout: layout)
    }
}

/// Workspace 卡片本身：標題、統計行、工作中狀態與版面圖按鈕。點了開版面圖，不是開聊天(#37 故事 11)。
private struct WorkspaceCardHeader: View {
    let card: WorkspaceCard
    let showLayout: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: showLayout) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 24)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: title)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(verbatim: card.summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if card.status == .working || card.status == .blocked {
                            StatusLabel(status: card.status)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint(Text("Shows the layout"))
            .accessibilityIdentifier("workspace.card.\(card.id)")

            // 版面圖按鈕(田字格);觸控目標 44×44 pt。
            // frame 放在 label 裡:放在 Button 外面時，可點範圍與 accessibility frame 仍只有圖示大小(#35 audit)。
            Button(action: showLayout) {
                Label("Workspace Layout", systemImage: "square.grid.2x2")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("workspace.layout.\(card.id)")
        }
    }

    /// 非選取中主機：標題以主機名開頭(行為規格 F2.1)。
    private var title: String {
        card.hostLabel.map { "\($0.name) · \(card.label)" } ?? card.label
    }
}

/// 卡片裡 tab 不只一個時的 tab 名稱。
private struct TabGroupTitle: View {
    let title: String

    var body: some View {
        Text(verbatim: title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
            .cardRail()
    }
}

/// 終端機列：標題「Terminal」,副標是程式名與資料夾(#37 故事 14)。
struct TerminalRowView: View {
    let row: TerminalRow
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "apple.terminal")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(minWidth: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Terminal")
                    .font(.body)
                Text(verbatim: row.subtitle)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private extension View {
    /// 卡片下方的列：內縮，左側一條「軌道」表示屬於上面的卡片。
    func cardRail() -> some View {
        padding(.leading, 20)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                    .frame(width: 3)
                    .padding(.vertical, -4)
                    .accessibilityHidden(true)
            }
    }
}

/// 持有 Pane 終端機 model 的容器:navigationDestination 或視窗的內容可能被重建，model 只在第一次建立。
struct PaneTerminalScreen: View {
    @State private var model: PaneTerminalModel

    init(model: @autoclosure () -> PaneTerminalModel) {
        _model = State(wrappedValue: model())
    }

    var body: some View {
        #if canImport(UIKit)
        PaneTerminalView(model: model)
        #else
        EmptyView()
        #endif
    }
}

extension AgentListMode {
    /// 列表大標題(也是切換選單的項目)。
    var title: LocalizedStringKey {
        switch self {
        case .spaces: "Spaces"
        case .agents: "Agents"
        }
    }
}

/// 檢視選單的內容(目前那個打勾)。
struct AgentListModePicker: View {
    @Binding var mode: AgentListMode

    var body: some View {
        Picker("View", selection: $mode) {
            ForEach(AgentListMode.allCases, id: \.self) { mode in
                Text(mode.title).tag(mode)
            }
        }
    }
}
