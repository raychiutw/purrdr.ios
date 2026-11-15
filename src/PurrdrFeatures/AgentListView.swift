import PurrdrCore
import SwiftUI

/// Agent 列表(DESIGN.md 方向 A):系統 grouped list,依「需要你／工作中／閒置」分 section。
///
/// 畫面可見且 app 在前景時才即時更新(長駐的訂閱通道在背景是 iOS 第一個殺的，行為規格 §3.7)。
/// app 在前景時，新的「需要你」只出現在列表裡，這個畫面不發任何系統通知。
public struct AgentListView: View {
    @Bindable var model: AgentListModel
    @Environment(\.scenePhase) private var scenePhase
    /// 為某個 Agent 的 Pane 建立終端機畫面的 model(由 composition root 注入)。
    let makeTerminal: ((AgentRow) -> PaneTerminalModel)?
    @State private var terminal: PaneTerminalModel?

    public init(model: AgentListModel, makeTerminal: ((AgentRow) -> PaneTerminalModel)? = nil) {
        self.model = model
        self.makeTerminal = makeTerminal
    }

    /// 放在呼叫端的 `NavigationStack` 裡(導覽層與工具列見 `TopNavigationView`)。
    public var body: some View {
        content
            .navigationTitle("Agents")
            .task(id: scenePhase == .active) {
                guard scenePhase == .active else { return }
                await model.run()
            }
            #if canImport(UIKit)
            .navigationDestination(isPresented: Binding(
                get: { terminal != nil }, set: { if !$0 { terminal = nil } }
            )) {
                if let terminal { PaneTerminalView(model: terminal) }
            }
            #endif
    }

    private func openTerminal(_ row: AgentRow) {
        terminal = makeTerminal?(row)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading where !model.hasAgents:
            ProgressView("Loading agents…")
        case .failed(let message) where !model.hasAgents:
            ContentUnavailableView {
                Label("Can’t Load Agents", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await model.load() } }
            }
        case .loaded where !model.hasAgents:
            ContentUnavailableView(
                "No Agents",
                systemImage: "bubble.left.and.text.bubble.right",
                description: Text("Agents you start in herdr on this host appear here.")
            )
        default:
            list
        }
    }

    private var list: some View {
        let sections = model.sections
        return List {
            ForEach(sections) { section in
                Section(section.group.title) {
                    ForEach(section.rows) { row in
                        AgentRowView(row: row)
                            .swipeActions(edge: .trailing) {
                                if makeTerminal != nil {
                                    // Agent 對話畫面還沒做(#12);先從列表的滑動動作進終端機。
                                    PaneTerminalButton { openTerminal(row) }
                                        .tint(.gray)
                                }
                            }
                    }
                }
            }
            if case .failed(let message) = model.phase {
                // 列已經在畫面上時，錯誤放在列下方，不把列推走(行為規格 F2.9)。
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("agentList.error")
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .overlay {
            if sections.isEmpty, !model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                ContentUnavailableView(
                    "No Matching Agents",
                    systemImage: "magnifyingglass",
                    description: Text("Try a different name, agent, or folder.")
                )
            }
        }
        .searchable(text: $model.query, prompt: Text("Search"))
        .autocorrectionDisabled()
        #if os(iOS)
        .textInputAutocapitalization(.never)
        #endif
    }
}

struct AgentRowView: View {
    let row: AgentRow
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top) {
                texts
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 4) {
                    StatusLabel(status: row.status)
                    timeText
                }
                .fixedSize()
            }
            // AX 字級放不下時改成上下堆疊，不截斷。
            VStack(alignment: .leading, spacing: 4) {
                texts
                StatusLabel(status: row.status)
                timeText
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("agent.row.\(row.id)")
    }

    /// AX 字級時不限制行數(DESIGN.md:支援到 AX5 不截斷)。
    private func lines(_ limit: Int) -> Int? {
        dynamicTypeSize.isAccessibilitySize ? nil : limit
    }

    private var texts: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.title)
                .font(.body)
                .lineLimit(lines(2))
            Text(row.subtitle)
                .font(.subheadline.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(lines(1))
            preview
                .font(.subheadline)
                .lineLimit(lines(1))
        }
    }

    @ViewBuilder
    private var preview: some View {
        switch row.preview {
        case .needsInput:
            Text("Waiting for your input")
                .foregroundStyle(.tint)
        case .message(let text, let fromYou):
            Text(fromYou ? "You: \(text)" : "\(text)")
                .foregroundStyle(.secondary)
        case .status(let status):
            Text(status.title)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var timeText: some View {
        if let time = row.time {
            Text(time.text())
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

/// Agent 狀態同時用文字、符號形狀與顏色表示，不只靠顏色(DESIGN.md)。
/// 顏色只上在符號：文字維持次要色，確保對比;「需要你」整個用 tint(品牌紅,`#D91E36` 對白底 5.0:1)。
struct StatusLabel: View {
    let status: AgentStatus

    var body: some View {
        Label {
            Text(status.title)
                .foregroundStyle(status == .blocked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        } icon: {
            Image(systemName: status.symbol)
                .foregroundStyle(status.color)
        }
        .font(.subheadline)
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

    /// 「需要你」一律有 `!` 符號(DESIGN.md 顏色一節)。每個狀態的形狀都不同。
    var symbol: String {
        switch self {
        case .blocked: "exclamationmark.circle.fill"
        case .working: "ellipsis.circle"
        case .done: "checkmark.circle.fill"
        case .idle: "circle"
        case .unknown: "questionmark.circle"
        }
    }

    /// 語意對應 herdr 側欄(行為規格 F2.5);用系統色，深淺色與高對比由系統處理。
    var color: AnyShapeStyle {
        switch self {
        case .blocked: AnyShapeStyle(.tint)
        case .working: AnyShapeStyle(.orange)
        case .done: AnyShapeStyle(.teal)
        case .idle: AnyShapeStyle(.green)
        case .unknown: AnyShapeStyle(.gray)
        }
    }
}
