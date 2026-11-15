import PurrdrCore
import SwiftUI

/// Agent 列表(DESIGN.md 方向 A):系統 grouped list,依「需要你／工作中／閒置」分 section。
///
/// 畫面可見且 app 在前景時才即時更新(長駐的訂閱通道在背景是 iOS 第一個殺的，行為規格 §3.7)。
/// app 在前景時，新的「需要你」只出現在列表裡，這個畫面不發任何系統通知。
public struct AgentListView: View {
    @Bindable var model: AgentListModel
    let actions: WorkspaceActionsModel
    @State private var presentation = WorkspacePresentation()
    /// 從版面圖選了 Agent 之後要開的聊天(pane id)。
    @State private var openedChat: String?
    @Environment(\.scenePhase) private var scenePhase
    /// 建立某個 Agent 的對話 model(pane id、列表看到的 session)。由 composition root 提供。
    private let makeConversation: @MainActor (String, String?) -> ConversationModel
    /// 建立某個 Pane 的終端機 model(pane id、標題)。由 composition root 提供。
    private let makeTerminal: (@MainActor (String, String) -> PaneTerminalModel)?
    /// 選取中主機的 Claude 用量，畫在列表最下方;讀取失敗時不顯示(行為規格 F2.9、F18)。
    private let usage: ClaudeUsageModel?

    public init(
        model: AgentListModel, actions: WorkspaceActionsModel, usage: ClaudeUsageModel? = nil,
        conversation: @escaping @MainActor (_ paneID: String, _ sessionID: String?) -> ConversationModel,
        terminal: (@MainActor (_ paneID: String, _ title: String) -> PaneTerminalModel)? = nil
    ) {
        self.model = model
        self.actions = actions
        self.makeConversation = conversation
        self.makeTerminal = terminal
        self.usage = usage
    }

    /// 放在呼叫端的 `NavigationStack` 裡(導覽層與工具列見 `TopNavigationView`)。
    public var body: some View {
        content
            .navigationTitle("Agents")
            .navigationDestination(for: String.self) { paneID in
                ConversationScreen(model: makeConversation(paneID, model.sessionID(ofPane: paneID)), makeTerminal: makeTerminal)
            }
            .navigationDestination(item: $openedChat) { paneID in
                ConversationScreen(model: makeConversation(paneID, model.sessionID(ofPane: paneID)), makeTerminal: makeTerminal)
            }
            .task(id: scenePhase == .active) {
                guard scenePhase == .active else { return }
                await model.run()
            }
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
                        NavigationLink(value: row.id) { AgentRowView(row: row) }
                            .accessibilityIdentifier("agent.row.\(row.id)")
                            .workspaceRowActions(
                                WorkspaceRowContext(paneID: row.id, snapshot: model.snapshot),
                                actions: actions, presentation: presentation, snapshot: model.snapshot
                            )
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
                    if model.isWaitingForRetry {
                        // 取消 Tailscale 重新驗證後不自動重試，由使用者決定何時再連。
                        Button("Try Again") { Task { await model.load() } }
                            .accessibilityIdentifier("agentList.retry")
                    }
                }
            } else if let usage {
                Section { ClaudeUsageFooter(model: usage) }
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
        // 版面圖選的 Pane:聊天推入對話;Pane 終端機畫面還沒有(Pane 終端機那張票接上)。
        .workspaceActionsPresentation(actions: actions, presentation: presentation) { target in
            if case .chat(let paneID) = target { openedChat = paneID }
        }
        .searchable(text: $model.query, prompt: Text("Search"))
        .autocorrectionDisabled()
        #if os(iOS)
        .textInputAutocapitalization(.never)
        #endif
    }
}

/// 持有對話 model 的容器:navigationDestination 的內容可能被重建，model 只在第一次建立。
private struct ConversationScreen: View {
    @State private var model: ConversationModel
    let makeTerminal: (@MainActor (String, String) -> PaneTerminalModel)?
    @State private var terminal: PaneTerminalModel?

    init(model: @autoclosure () -> ConversationModel, makeTerminal: (@MainActor (String, String) -> PaneTerminalModel)?) {
        _model = State(wrappedValue: model())
        self.makeTerminal = makeTerminal
    }

    var body: some View {
        ConversationView(model: model)
            .toolbar {
                if let makeTerminal {
                    // 標題列的終端機鈕：打開這個 Agent 自己的 Pane(#37 故事 43)。
                    ToolbarItem(placement: .primaryAction) {
                        PaneTerminalButton { terminal = makeTerminal(model.paneID, model.title.isEmpty ? model.paneID : model.title) }
                    }
                }
            }
            #if canImport(UIKit)
            .navigationDestination(isPresented: Binding(
                get: { terminal != nil }, set: { if !$0 { terminal = nil } }
            )) {
                if let terminal { PaneTerminalView(model: terminal) }
            }
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
