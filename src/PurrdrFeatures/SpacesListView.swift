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
                            WorkspaceTarget(workspaceID: section.workspaceID, label: section.workspace, snapshot: model.snapshot(for: section.host)),
                            host: section.host, snapshot: model.snapshot(for: section.host), presentation: presentation)
                        .accessibilityIdentifier("spaces.tab.\(tab.id)")
                }
            } header: {
                SpacesSectionHeader(section: section)
            }
        }
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
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("spaces.section.\(section.id)")
    }
}

/// Agent 種類頭像：36pt 圓角方塊，白色字母。種類由列的 VoiceOver 句子念(`AgentStatusAvatar` 整個隱藏)。
struct AgentKindAvatar: View {
    let kind: AgentKind

    var body: some View {
        let style = AgentKindAvatarStyle(kind: kind)
        Text(verbatim: style.letter)
            .font(.subheadline.bold())
            .foregroundStyle(.white)
            // 方塊固定大小，字母跟著放大會超出方塊。
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
            .frame(width: 36, height: 36)
            .background(RoundedRectangle(cornerRadius: 10).fill(style.palette.color))
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

/// 列表第一列的 Agents／Spaces 分段控制(#268):檢視切換只有這一個入口，沒有大標題、也不在任何選單裡。
struct AgentListModeControl: View {
    @Binding var mode: AgentListMode

    var body: some View {
        Picker("View", selection: $mode) {
            ForEach([AgentListMode.agents, .spaces], id: \.self) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("agentList.mode")
    }
}

/// Agents 檢視的搜尋欄(#268):放在分段控制下方(原型 purrdr-screens 定案版),不用 `.searchable`(iOS 26 會放到底部工具列)。
struct AgentListSearchField: View {
    @Binding var query: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondaryText)
                .accessibilityHidden(true)
            TextField("Search", text: $query)
                .focused(focused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .accessibilityIdentifier("agentList.search")
            if !query.isEmpty {
                Button("Clear Search", systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondaryText)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("agentList.search.clear")
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 44)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
    }
}
