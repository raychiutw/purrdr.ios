import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// Spaces(#275,原型 purrdr-screens 定案版;#501 起是聊天 tab 唯一的呈現):每個「主機圖示 主機 · workspace」一段，段內每個 Tab 一列(名稱與 ›)。
///
/// 點 Tab:只有一個 pane 直接開(以 `ChatRoute` 導覽，Agent 開對話、其他開 Pane 終端機，iPad 是對話欄選取);
/// 多個 pane 開那個 Tab 的版面圖選 Pane。長按是 workspace 的動作(版面圖、重新命名、新 worktree、關閉)。
struct SpacesSectionsContent: View {
    let sections: [SpacesSection]
    let model: MergedAgentListModel
    let presentation: WorkspacePresentation
    /// 把 Tab 開在新視窗(支援多視窗時才有)。
    var openInNewWindow: ((PaneWindow.Kind, ChatRoute, String) -> Void)?
    /// 標題選單的「在此新增聊天」(#537)。
    var newChatInWorkspace: ((HostSelection, String) -> Void)?
    var canNewChatInWorkspace: ((HostSelection) -> Bool)?

    var body: some View {
        ForEach(sections) { section in
            Section {
                ForEach(section.tabs) { tab in
                    tabRow(tab, in: section)
                        .workspaceActionsMenu(
                            workspaceTarget(section),
                            tab: TabTarget(tabID: tab.key, snapshot: model.snapshot(for: section.host), workspaceLabel: section.workspace),
                            host: section.host, snapshot: model.snapshot(for: section.host), presentation: presentation,
                            chats: TabChatActions(actions: model.actions(for: section.host), sessionIDs: tab.chatSessionIDs),
                            openInNewWindow: newWindowAction(tab, host: section.host))
                        .accessibilityIdentifier("spaces.tab.\(tab.id)")
                }
            } header: {
                SpacesSectionHeader(section: section)
                    .workspaceHeaderMenu(
                        workspaceTarget(section), host: section.host, snapshot: model.snapshot(for: section.host),
                        isReadOnly: model.actions(for: section.host)?.isReadOnly ?? false, presentation: presentation,
                        newChatHere: newChatHere(section))
            }
        }
    }

    /// 這台主機支援時,標題選單的「在此新增聊天」動作。
    private func newChatHere(_ section: SpacesSection) -> (() -> Void)? {
        guard let newChatInWorkspace, canNewChatInWorkspace?(section.host) == true else { return nil }
        return { newChatInWorkspace(section.host, section.workspaceID) }
    }

    private func newWindowAction(_ tab: SpacesTab, host: HostSelection) -> (() -> Void)? {
        guard let openInNewWindow, let opening = tab.newWindowOpening else { return nil }
        return { openInNewWindow(opening.isTerminal ? .terminal : .chat, ChatRoute(host: host, paneID: opening.paneID), opening.title) }
    }

    private func workspaceTarget(_ section: SpacesSection) -> WorkspaceTarget {
        WorkspaceTarget(workspaceID: section.workspaceID, label: section.workspace, snapshot: model.snapshot(for: section.host))
    }

    @ViewBuilder
    private func tabRow(_ tab: SpacesTab, in section: SpacesSection) -> some View {
        switch tab.target {
        case .pane(let route):
            NavigationLink(value: route) {
                ChatRowView(content: ChatRowContent(tab: tab))
            }
            .listRowInsets(ChatRowView.rowInsets)
            .accessibilityLabel(Text(verbatim: ChatRowView.accessibilityText(tab)))
            .selectionFill(for: route)
        case .layout(let workspaceID, let tabID):
            Button {
                // 顯示開啟當下的 snapshot,只畫這個 Tab(行為規格 F4)。
                presentation.host = section.host
                let layout = model.snapshot(for: section.host).flatMap { SpacesLayout(snapshot: $0, workspaceID: workspaceID) }
                presentation.sheet = .layout(workspaceLabel: tab.title, layout: layout?.onlyTab(tabID))
            } label: {
                HStack {
                    ChatRowView(content: ChatRowContent(tab: tab))
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .listRowInsets(ChatRowView.rowInsets)
            .accessibilityLabel(Text(verbatim: ChatRowView.accessibilityText(tab)))
            .accessibilityHint(Text("Shows this tab’s layout."))
        }
    }
}

/// 段落標題：主機圖示與「主機 · workspace」(標為 header,VoiceOver 可以在 workspace 之間跳)。
private struct SpacesSectionHeader: View {
    let section: SpacesSection

    var body: some View {
        HStack(spacing: 6) {
            HostIconBadge(section.hostIcon, diameter: 20)
            Text(verbatim: "\(section.hostName) · \(section.workspace)")
                .fixedSize(horizontal: false, vertical: true)
        }
        // 固定的次要文字色(系統 section header 的灰色對比不到 4.5:1,audit「nearly passed」);不轉大寫。
        .font(.subheadline)
        // 段落標題是分組用的次要文字:放大到 accessibility1 為止(與頭像同上限),AX5 不會折成好幾行。
        .dynamicTypeSize(...AgentStatusAvatar.largestTypeSize)
        .foregroundStyle(Color.secondaryText)
        .textCase(nil)
        // 整列寬都能長按(標題的長按選單,#456)。
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("spaces.section.\(section.id)")
    }
}

/// Agent 種類頭像：圓角方塊，白色字母。種類由列的 VoiceOver 句子念(`AgentStatusAvatar` 整個隱藏)。
struct AgentKindAvatar: View {
    let kind: AgentKind
    static let baseSide: CGFloat = 36
    // 方塊隨字級放大但有上限(#314、使用者決定);字母用實際字級(固定字級的字母會被稽核判為 Dynamic Type 不支援)。
    private let size: AvatarBox.Size

    /// `compact` 是對話裡每輪開頭的小頭像(#351,20pt);`size: .row` 是聊天列的頭像(#502)。
    init(kind: AgentKind, compact: Bool = false) {
        self.init(kind: kind, size: compact ? .compact : .regular)
    }

    init(kind: AgentKind, size: AvatarBox.Size) {
        self.kind = kind
        self.size = size
    }

    var body: some View {
        let style = AgentKindAvatarStyle(kind: kind)
        AvatarBox(fill: style.palette.color, size: size)
            .dynamicTypeSize(...AgentStatusAvatar.largestTypeSize)
            .overlay {
                Text(verbatim: style.letter)
                    .font(letterFont)
                    .foregroundStyle(.white)
            }
    }

    private var letterFont: Font {
        switch size {
        case .compact: .caption2.bold()
        case .regular: .subheadline.bold()
        case .row: .headline.bold()
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
            .hidesTabBarWhenCompact()
        #else
        EmptyView()
        #endif
    }
}
