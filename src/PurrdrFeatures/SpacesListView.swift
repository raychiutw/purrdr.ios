import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// Spaces 檢視(#275,原型 purrdr-screens 定案版):每個「主機圖示 主機 · workspace」一段，段內每個 Tab 一列(名稱與 ›)。
///
/// 點 Tab:只有一個 pane 直接開(以 `ChatRoute` 導覽，Agent 開對話、其他開 Pane 終端機，iPad 是對話欄選取);
/// 多個 pane 開那個 Tab 的版面圖選 Pane。長按是 workspace 的動作(版面圖、重新命名、新 worktree、關閉)。
struct SpacesSectionsContent: View {
    let sections: [SpacesSection]
    let model: MergedAgentListModel
    let presentation: WorkspacePresentation

    var body: some View {
        ForEach(sections) { section in
            Section {
                ForEach(section.tabs) { tab in
                    tabRow(tab, in: section)
                        .workspaceActionsMenu(
                            workspaceTarget(section),
                            tab: TabTarget(tabID: tab.key, snapshot: model.snapshot(for: section.host), workspaceLabel: section.workspace),
                            host: section.host, snapshot: model.snapshot(for: section.host), presentation: presentation)
                        .accessibilityIdentifier("spaces.tab.\(tab.id)")
                }
            } header: {
                SpacesSectionHeader(section: section)
                    .workspaceHeaderRename(
                        workspaceTarget(section), host: section.host,
                        isReadOnly: model.actions(for: section.host)?.isReadOnly ?? false, presentation: presentation)
            }
        }
    }

    private func workspaceTarget(_ section: SpacesSection) -> WorkspaceTarget {
        WorkspaceTarget(workspaceID: section.workspaceID, label: section.workspace, snapshot: model.snapshot(for: section.host))
    }

    @ViewBuilder
    private func tabRow(_ tab: SpacesTab, in section: SpacesSection) -> some View {
        switch tab.target {
        case .pane(let route):
            NavigationLink(value: route) {
                SpacesTabLabel(tab: tab)
            }
            .accessibilityLabel(Text(verbatim: SpacesTabLabel.accessibilityText(tab)))
            .selectionFill(for: route)
        case .layout(let workspaceID, let tabID):
            Button {
                // 顯示開啟當下的 snapshot,只畫這個 Tab(行為規格 F4)。
                presentation.host = section.host
                let layout = model.snapshot(for: section.host).flatMap { SpacesLayout(snapshot: $0, workspaceID: workspaceID) }
                presentation.sheet = .layout(workspaceLabel: tab.title, layout: layout?.onlyTab(tabID))
            } label: {
                HStack {
                    SpacesTabLabel(tab: tab)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .accessibilityLabel(Text(verbatim: SpacesTabLabel.accessibilityText(tab)))
            .accessibilityHint(Text("Shows this tab’s layout."))
        }
    }
}

/// Tab 列的內容(#316):頭像＋右下角狀態與 Tab 名稱。頭像對 VoiceOver 隱藏;列(按鈕本身)念 `accessibilityText`。
struct SpacesTabLabel: View {
    let tab: SpacesTab

    var body: some View {
        HStack(spacing: 12) {
            switch tab.avatar {
            case .agent(let kind, let status):
                AgentStatusAvatar(content: .agent(AgentKind(rawKind: kind)), status: status)
            case .terminal:
                AgentStatusAvatar(content: .terminal, status: nil)
            }
            // 按鈕列(多個 pane)的 label 會被 tint 染成主色;`.primary` 在按鈕裡解析成 tint,要用 `Color.primary`。
            Text(verbatim: tab.title)
                .foregroundStyle(Color.primary)
        }
    }

    /// 「名稱, 種類, 狀態」;只有終端機時「名稱, 終端機」。
    static func accessibilityText(_ tab: SpacesTab) -> String {
        let parts: [String?] = switch tab.avatar {
        case .agent(let kind, let status): [tab.title, AgentKind(rawKind: kind).displayName, String(localized: status.title)]
        case .terminal: [tab.title, String(localized: "Terminal")]
        }
        return parts.compactMap { $0 }.joined(separator: ", ")
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

/// Agent 種類頭像：36pt 圓角方塊，白色字母。種類由列的 VoiceOver 句子念(`AgentStatusAvatar` 整個隱藏)。
struct AgentKindAvatar: View {
    let kind: AgentKind
    static let baseSide: CGFloat = 36
    // 方塊隨字級放大但有上限(#314、使用者決定);字母用實際字級(固定字級的字母會被稽核判為 Dynamic Type 不支援)。
    private let compact: Bool

    /// `compact` 是對話裡每輪開頭的小頭像(#351,20pt)。
    init(kind: AgentKind, compact: Bool = false) {
        self.kind = kind
        self.compact = compact
    }

    var body: some View {
        let style = AgentKindAvatarStyle(kind: kind)
        AvatarBox(fill: style.palette.color, compact: compact)
            .dynamicTypeSize(...AgentStatusAvatar.largestTypeSize)
            .overlay {
                Text(verbatim: style.letter)
                    .font(compact ? .caption2.bold() : .subheadline.bold())
                    .foregroundStyle(.white)
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

extension AgentListMode {
    /// 列表大標題(也是切換選單的項目)。
    var title: LocalizedStringKey {
        switch self {
        case .spaces: "Spaces"
        case .agents: "Agents"
        }
    }
}

extension AgentListMode {
    /// 左上角切換鈕的符號:顯示目前的檢視(#391)。
    var symbol: String {
        switch self {
        case .spaces: "square.grid.2x2"
        case .agents: "person.2"
        }
    }

    /// VoiceOver 念的目前檢視,例:「檢視:Agents」。
    var accessibilityName: String {
        switch self {
        case .spaces: String(localized: "View: Spaces")
        case .agents: String(localized: "View: Agents")
        }
    }

    /// VoiceOver 的提示:點兩下會切到另一個檢視。
    var switchHint: LocalizedStringKey {
        switch self {
        case .spaces: "Switches to Agents."
        case .agents: "Switches to Spaces."
        }
    }
}

/// 聊天 tab 左上角的 Agents／Spaces 一鍵切換(#391):只有符號、顯示目前檢視;點一下切換,長按出選單(兩列勾選)。
/// 其他 tab 這個位置留空。
struct AgentListModeButton: View {
    @Bindable var list: MergedAgentListModel

    var body: some View {
        Menu {
            Picker("View", selection: $list.mode) {
                ForEach([AgentListMode.agents, .spaces], id: \.self) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(list.mode.title, systemImage: list.mode.symbol)
                .labelStyle(.iconOnly)
        } primaryAction: {
            list.toggleMode()
        }
        .accessibilityLabel(Text(verbatim: list.mode.accessibilityName))
        .accessibilityHint(Text(list.mode.switchHint))
        .accessibilityIdentifier("agentList.mode")
    }
}

extension View {
    /// 聊天列表的系統搜尋欄(#391):放在導覽列下方的抽屜(iOS 26 的 `.automatic` 會移到底部工具列,與 tab bar 擠在一起)。
    /// 抽屜用 `.always`:導覽列是 inline 標題(中間是主機選單),`.automatic` 會在列表頂端時也收著、要下拉才出現;
    /// 代價是捲動時不會收起(偏離設計稿「捲動才收起」)。
    @ViewBuilder
    func agentListSearch(text: Binding<String>, focused: FocusState<Bool>.Binding) -> some View {
        #if os(iOS)
        searchable(text: text, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Search"))
            .searchFocused(focused)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
        #else
        searchable(text: text, prompt: Text("Search"))
        #endif
    }
}
