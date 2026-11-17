import PurrdrCore
import SwiftUI

/// Spaces 檢視的 section(#103):已釘選組與每台主機一組。單一 agent 的 workspace 是聊天列，其他是可收合的群組。
///
/// 終端機列跟 Agent 列一樣以 `ChatRoute`(主機 + pane id)導覽:pane 不是 agent 時開的是 Pane 終端機，
/// 所以 iPad 的 split view 選取與 iPhone 的推入都不用另外處理。
struct SpacesSectionsContent<AgentRowContent: View>: View {
    let sections: [SpacesSection]
    let model: MergedAgentListModel
    let presentation: WorkspacePresentation
    /// 跟 Agents 檢視同樣的滑動、選單、已讀與釘選;列的版面是 `SpacesAgentRowView`。
    @ViewBuilder let agentRow: (AgentRow) -> AgentRowContent

    var body: some View {
        ForEach(sections) { section in
            Section {
                ForEach(section.items) { item in
                    switch item {
                    case .chat(let row):
                        agentRow(row)
                    case .group(let group):
                        WorkspaceGroupHeader(group: group) { model.toggleExpanded(group) }
                            .workspaceGroupActions(
                                workspaceID: group.workspaceID, label: group.label, host: group.host,
                                snapshot: model.snapshot(for: group.host), presentation: presentation)
                        if group.isExpanded {
                            ForEach(group.rows) { row in
                                switch row {
                                case .agent(let row):
                                    agentRow(row)
                                case .terminal(let row):
                                    NavigationLink(value: row.route) {
                                        TerminalRowView(row: row)
                                    }
                                    .accessibilityIdentifier("terminal.row.\(row.id)")
                                }
                            }
                        }
                    }
                }
            } header: {
                switch section.kind {
                case .pinned: AgentSectionHeader(group: .pinned, count: section.items.count)
                case .host(let host): SpacesHostHeader(host: host)
                }
            }
        }
    }
}

extension AgentStatus {
    /// 狀態條與圖例的顏色;閒置用低飽和的 `idleSegment`(#103)。
    var segmentColor: AnyShapeStyle {
        switch self {
        case .idle, .unknown: AnyShapeStyle(AccessibleColors.idleSegment.color)
        default: color
        }
    }
}

extension SpacesStatusCounts {
    /// 數量不為 0 的狀態，依需要你 > 工作中 > 完成 > 閒置。
    var nonZero: [(status: AgentStatus, count: Int)] {
        [(AgentStatus.blocked, needsYou), (.working, working), (.done, done), (.idle, idle)].filter { $0.1 > 0 }
    }

    /// VoiceOver 用:「Needs You 1」「Working 2」。
    var spokenText: [String] {
        nonZero.map { "\(String(localized: $0.status.title)) \($0.count)" }
    }
}

/// 圖例「● 需要你 1  ● 工作中 2」:狀態同時有符號、文字與顏色;項目放不下時換行。
struct StatusLegend: View {
    let counts: SpacesStatusCounts
    /// 圖例前的文字(已釘選組的主機名)。
    var leading: String?
    /// 圖例後的文字(終端機數)。
    var trailing: String?

    var body: some View {
        FlowLayout(spacing: 10, lineSpacing: 2) {
            if let leading {
                Text(verbatim: leading)
            }
            ForEach(counts.nonZero, id: \.status) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: entry.status.symbol)
                        .foregroundStyle(entry.status.segmentColor)
                    Text(entry.status.title)
                    Text(entry.count, format: .number)
                        .monospacedDigit()
                }
            }
            if let trailing {
                Text(verbatim: trailing)
            }
        }
    }
}

/// 依寬度換行的水平排列：一行放不下就換到下一行，單一項目比一行寬時由它自己換行。
struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = arrange(subviews, width: proposal.width ?? .infinity)
        let width = frames.map(\.maxX).max() ?? 0
        let height = frames.map(\.maxY).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(subviews, width: bounds.width)
        for (subview, frame) in zip(subviews, frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    private func arrange(_ subviews: Subviews, width maxWidth: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var origin = CGPoint.zero
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            if origin.x > 0, origin.x + size.width > maxWidth {
                origin = CGPoint(x: 0, y: origin.y + lineHeight + lineSpacing)
                lineHeight = 0
            }
            frames.append(CGRect(origin: origin, size: size))
            origin.x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return frames
    }
}

/// 主機組標題：主機圖示、主機名與各狀態的 Agent 數量(#103 故事 2–3、36)。
private struct SpacesHostHeader: View {
    let host: SpacesHost
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        layout {
            Label {
                Text(verbatim: host.name)
                    .font(.title3.bold())
                    .foregroundStyle(.primary)
            } icon: {
                Image(systemName: host.icon.symbol)
                    .foregroundStyle(.secondary)
            }
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
            StatusLegend(counts: host.counts)
                .font(.footnote)
                .foregroundStyle(.secondaryText)
        }
        .textCase(nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: ([host.name] + host.counts.spokenText).joined(separator: ", ")))
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("spaces.host.\(host.host.storedValue)")
    }
}

/// 群組的收合標頭(H2 狀態條):workspace 圖示、名稱 + Agent 數膠囊、狀態條與圖例。整列是一個按鈕，點了展開或收合。
private struct WorkspaceGroupHeader: View {
    let group: WorkspaceGroup
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "square.stack.3d.up")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 1.5))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: group.label)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if group.agentCount > 0 {
                            Text(group.agentCount, format: .number)
                                .font(.footnote.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(.secondaryText)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(.fill.tertiary))
                        }
                    }
                    if !group.bar.isEmpty {
                        StatusBarView(segments: group.bar)
                    }
                    StatusLegend(counts: group.counts, leading: group.hostName, trailing: legendTrailing)
                        .font(.footnote)
                        .foregroundStyle(.secondaryText)
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(group.isExpanded ? 90 : 0))
                    .frame(minHeight: 36)
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spokenLabel))
        .accessibilityHint(Text("Shows or hides the agents."))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("workspace.group.\(group.id)")
    }

    /// 圖例最後：有終端機時「終端機 N」;只有終端機時「N 個終端機」。
    private var legendTrailing: String? {
        guard group.terminalCount > 0 else { return nil }
        return group.agentCount > 0 ? String(localized: "Terminals \(group.terminalCount)") : terminalPhrase
    }

    private var terminalPhrase: String {
        group.terminalCount == 1 ? String(localized: "1 terminal") : String(localized: "\(group.terminalCount) terminals")
    }

    /// 「notes, 1 agent, 1 terminal, Working 1, Expanded」。
    private var spokenLabel: String {
        var parts = [group.label]
        if let hostName = group.hostName { parts.append(hostName) }
        if group.agentCount > 0 {
            parts.append(group.agentCount == 1 ? String(localized: "1 agent") : String(localized: "\(group.agentCount) agents"))
        }
        if group.terminalCount > 0 { parts.append(terminalPhrase) }
        parts += group.counts.spokenText
        parts.append(group.isExpanded ? String(localized: "Expanded") : String(localized: "Collapsed"))
        return parts.joined(separator: ", ")
    }
}

/// 分段色條：每段寬度與權重成正比，段間 2pt。對 VoiceOver 隱藏(數量在圖例與 label)。
private struct StatusBarView: View {
    let segments: [StatusSegment]
    private static let spacing: CGFloat = 2

    var body: some View {
        GeometryReader { proxy in
            let total = CGFloat(segments.map(\.weight).reduce(0, +))
            let available = max(proxy.size.width - Self.spacing * CGFloat(segments.count - 1), 0)
            HStack(spacing: Self.spacing) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    Capsule()
                        .fill(segment.status.segmentColor)
                        .frame(width: total > 0 ? available * CGFloat(segment.weight) / total : 0)
                }
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

/// Spaces 檢視的 Agent 列(#103):左側 Agent 種類頭像;標題、預覽各最多兩行;第三行狀態與說明(種類或 workspace 名稱)。
struct SpacesAgentRowView: View {
    let row: AgentRow
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// 選取中(iPad 的 split view 列以 tint 填滿):次要色改白色(同 `AgentRowView`)。
    @Environment(\.backgroundProminence) private var backgroundProminence

    private var secondary: AnyShapeStyle {
        backgroundProminence == .increased ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondaryText)
    }

    /// AX 字級時不限制行數(DESIGN.md:支援到 AX5 不截斷)。
    private func lines(_ limit: Int) -> Int? {
        dynamicTypeSize.isAccessibilitySize ? nil : limit
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AgentKindAvatar(kind: row.kind)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(row.title)
                        .font(row.status == .blocked ? .body.weight(.semibold) : .body)
                        .lineLimit(lines(2))
                    if row.isPinned {
                        Image(systemName: "pin.fill")
                            .imageScale(.small)
                            .foregroundStyle(secondary)
                            .accessibilityLabel(Text("Pinned"))
                    }
                    if row.isMuted {
                        Image(systemName: "bell.slash.fill")
                            .imageScale(.small)
                            .foregroundStyle(secondary)
                            .accessibilityLabel(Text("Muted"))
                    }
                    Spacer(minLength: 8)
                    if let time = row.time {
                        Text(time.text())
                            .font(.footnote)
                            .foregroundStyle(secondary)
                            .fixedSize()
                    }
                }
                preview
                    .font(.subheadline)
                    .lineLimit(lines(2))
                detail
                    .font(.subheadline)
                    .padding(.top, 2)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(row.isUnread ? Text("Unread") : Text(verbatim: ""))
    }

    @ViewBuilder
    private var preview: some View {
        switch row.preview {
        case .needsInput:
            Text("Waiting for your input")
                .foregroundStyle(backgroundProminence == .increased ? AnyShapeStyle(Color.white) : AnyShapeStyle(.tint))
        case .message(let text, let fromYou):
            Text(fromYou ? "You: \(text)" : "\(text)")
                .foregroundStyle(secondary)
        case .none:
            EmptyView()
        }
    }

    /// 狀態(符號 + 文字 + 顏色)· 種類或 workspace 名稱;已釘選組的列有主機圖示。
    private var detail: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            StatusLabel(status: row.status)
                .fixedSize()
            if !row.subtitle.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if let label = row.hostLabel {
                        Image(systemName: label.icon.symbol)
                            .accessibilityHidden(true)
                    }
                    Text(row.subtitle)
                        .lineLimit(lines(1))
                }
                .foregroundStyle(secondary)
            }
        }
    }
}

/// Agent 種類頭像：36pt 圓角方塊，白色字母。種類名稱在列的文字裡，對 VoiceOver 隱藏。
struct AgentKindAvatar: View {
    let kind: String

    var body: some View {
        let style = AgentKindAvatarStyle(kind: kind)
        Text(verbatim: style.letter)
            .font(.subheadline.bold())
            .foregroundStyle(.white)
            // 方塊固定大小，字母跟著放大會超出方塊。
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
            .frame(width: 36, height: 36)
            .background(RoundedRectangle(cornerRadius: 10).fill(style.palette.color))
            .accessibilityHidden(true)
    }
}

/// 終端機列：標題「Terminal」,副標是程式名與資料夾(#37 故事 14)。
struct TerminalRowView: View {
    let row: TerminalRow
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// 選取中(tint 填滿的底)次要色改白色(同 `AgentRowView`)。
    @Environment(\.backgroundProminence) private var backgroundProminence

    private var secondary: AnyShapeStyle {
        backgroundProminence == .increased ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondaryText)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "apple.terminal")
                .font(.body)
                .foregroundStyle(secondary)
                .frame(minWidth: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Terminal")
                    .font(.body)
                Text(verbatim: row.subtitle)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            }
        }
        .accessibilityElement(children: .combine)
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

/// 列表的大標題(#66):目前檢視名 + ⌄,點了出檢視選單。樣子同系統大標題(Large Title 粗體、靠前緣);
/// 它是一般的 `Menu`,所以 VoiceOver 唸「Spaces,按鈕」(另帶標題特徵，轉子的「標題」找得到)、UI 測試也找得到。
/// AX 字級時換行，不截斷。
struct AgentListLargeTitle: View {
    @Binding var mode: AgentListMode

    var body: some View {
        Menu {
            AgentListModePicker(mode: $mode)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(mode.title)
                    .font(.largeTitle.bold())
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.down")
                    .font(.title3.bold())
                    .foregroundStyle(.secondaryText)
                    .accessibilityHidden(true)
            }
            // 觸控目標至少 44pt 高(HIG 20.2)。
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Switches between Spaces and Agents.")
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("agentList.title")
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
