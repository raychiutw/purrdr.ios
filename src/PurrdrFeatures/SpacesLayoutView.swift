import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// Spaces 版面圖的 sheet(行為規格 F4,iPhone 版):每個 tab 一張分頁圖，點 pane 方塊開聊天或終端機。
///
/// 點方塊只記下目標並關 sheet;由列表在 sheet 關閉後才開(不能在關 sheet 的同一刻 push)。
/// iPad 有指標停留時改用浮動卡片(`LayoutCard`,#31);iPhone 與 context menu 的「Show Layout」仍是這個 sheet。
struct SpacesLayoutSheet: View {
    let workspaceLabel: String
    let layout: SpacesLayout?
    let onChoose: (PaneOpenTarget) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(workspaceLabel)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var content: some View {
        SpacesLayoutContent(layout: layout) { target in
            onChoose(target)
            dismiss()
        }
    }
}

/// 版面圖的內容(sheet 與 iPad 浮動卡片共用):每個 tab 一張圖;沒有版面時說明。
struct SpacesLayoutContent: View {
    let layout: SpacesLayout?
    /// 最多幾欄(浮動卡片只有 340pt 寬，一欄)。
    var maxColumns = 2
    let onChoose: (PaneOpenTarget) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if let layout, !layout.tabs.isEmpty {
            ScrollView {
                LazyVGrid(columns: columns(for: layout), alignment: .leading, spacing: 20) {
                    ForEach(layout.tabs) { tab in
                        LayoutTabView(tab: tab, onChoose: onChoose)
                    }
                }
                .padding()
            }
        } else {
            ContentUnavailableView(
                "No Layout",
                systemImage: "rectangle.split.3x1",
                description: Text("herdr on this host didn’t report a layout.")
            )
        }
    }

    /// 2 個以上的 tab 排兩欄;AX 字級改一欄，文字才放得下。
    private func columns(for layout: SpacesLayout) -> [GridItem] {
        let count = layout.tabs.count > 1 && !dynamicTypeSize.isAccessibilitySize ? maxColumns : 1
        return Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: count)
    }
}

/// 一個 tab:標題(作用中的強調)+ 依 herdr 版面排好的 pane 方塊。
private struct LayoutTabView: View {
    let tab: SpacesLayout.Tab
    let onChoose: (PaneOpenTarget) -> Void

    private var title: String {
        tab.label ?? String(localized: "Tab \(tab.number)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(tab.isActive ? .semibold : .regular))
                    .foregroundStyle(tab.isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondaryText))
                if tab.isActive {
                    Text("Active")
                        .font(.caption)
                        .foregroundStyle(.secondaryText)
                }
                if tab.isZoomed {
                    Image(systemName: "plus.magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.secondaryText)
                        .accessibilityLabel("Zoomed")
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityTitle)
            .accessibilityAddTraits(.isHeader)

            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    ForEach(tab.blocks) { block in
                        LayoutBlockView(block: block, onChoose: onChoose)
                            .frame(width: proxy.size.width * block.frame.width, height: proxy.size.height * block.frame.height)
                            .offset(x: proxy.size.width * block.frame.x, y: proxy.size.height * block.frame.y)
                    }
                }
            }
            .aspectRatio(tab.aspectRatio, contentMode: .fit)
            .padding(3)
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(tab.isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator), lineWidth: tab.isActive ? 2 : 1)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("layout.tab.\(tab.id)")
    }

    /// 「名稱、作用中、N 個 pane」。
    private var accessibilityTitle: String {
        var parts = [title]
        if tab.isActive { parts.append(String(localized: "Active")) }
        if tab.isZoomed { parts.append(String(localized: "Zoomed")) }
        parts.append(String(localized: "\(tab.paneCount) panes"))
        return parts.joined(separator: ", ")
    }
}

/// 一個 pane 方塊。Agent 用填色、shell 用中性色;「需要你」用橙色 `!` 符號加中性底(不只靠顏色);聚焦的 pane 有 2pt tint 外環。
private struct LayoutBlockView: View {
    let block: SpacesLayout.Block
    let onChoose: (PaneOpenTarget) -> Void

    var body: some View {
        Button {
            if let target = block.target { onChoose(target) }
        } label: {
            label
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(6)
                .background(fill, in: .rect(cornerRadius: 6))
                .overlay {
                    if block.isFocused {
                        RoundedRectangle(cornerRadius: 6).strokeBorder(.tint, lineWidth: 2)
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(block.target == nil)
        .padding(2)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
        .accessibilityIdentifier("layout.block.\(block.id)")
    }

    @ViewBuilder
    private var label: some View {
        switch block.content {
        case .agent(let name, let detail, let status):
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: status.symbol)
                        .foregroundStyle(status.tone.style)
                    Text(name).font(.caption.weight(.semibold))
                }
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondaryText)
                }
            }
            .lineLimit(2)
        case .terminal(let program):
            Label {
                Text(program.isEmpty ? String(localized: "Terminal") : program)
                    .font(.caption.monospaced())
            } icon: {
                Image(systemName: "terminal")
            }
            .foregroundStyle(.secondaryText)
            .lineLimit(2)
        case .unavailable:
            Image(systemName: "questionmark")
                .foregroundStyle(.secondaryText)
        }
    }

    private var fill: AnyShapeStyle {
        switch block.content {
        case .agent(_, _, .blocked): AnyShapeStyle(Color.gray.opacity(0.18))
        case .agent: AnyShapeStyle(.fill.secondary)
        case .terminal, .unavailable: AnyShapeStyle(.fill.quaternary)
        }
    }

    /// 「Claude Code、標題、狀態、已聚焦」。
    private var accessibilityLabel: String {
        var parts: [String] = []
        switch block.content {
        case .agent(let name, let detail, let status):
            parts.append(name)
            if let detail { parts.append(detail) }
            parts.append(String(localized: status.title))
        case .terminal(let program):
            parts.append(String(localized: "Terminal"))
            if !program.isEmpty { parts.append(program) }
        case .unavailable:
            parts.append(String(localized: "Pane"))
        }
        if block.isFocused { parts.append(String(localized: "Focused")) }
        return parts.joined(separator: ", ")
    }

    private var accessibilityHint: Text {
        switch block.target {
        case .chat: Text("Opens the chat.")
        case .terminal: Text("Opens the terminal.")
        case nil: Text("Can’t be opened.")
        }
    }
}
