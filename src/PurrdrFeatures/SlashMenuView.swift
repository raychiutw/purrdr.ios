import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 輸入列上方的 slash 選單(#15;HIG 20.6、DESIGN.md「輸入列」)。
///
/// - 只有 `/` 時依來源分組(內建、專案、使用者、各 plugin、其他);輸入名稱後是沒有標題的單一排名清單(#45)。
///   每列以指令名開頭，參數提示淡色等寬，說明在第二行。
/// - 高度最多 260pt(清單用 LazyVStack,畫面外的列不進無障礙樹,#256),內捲;點選不收鍵盤。硬體鍵盤上下選擇時高亮列捲進畫面。
/// - 清單不完整(主機上的發現逾時)時，底部照實標示。
/// - 內容層：不用玻璃，用 bar 背景(和送出提示一樣)。
struct SlashMenuView: View {
    let menu: SlashMenuModel
    /// 內容高度(上限 `maximumHeight`):清單是 lazy,畫面外的列不進無障礙樹(#256),所以高度不能靠 fixedSize 量整份內容，改由捲動區回報。
    @State private var contentHeight = SlashMenuView.maximumHeight
    private static let maximumHeight: CGFloat = 260

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if menu.isLoading {
                        Label("Loading Commands…", systemImage: "ellipsis")
                            .font(.footnote)
                            .foregroundStyle(.secondaryText)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(.horizontal, 12)
                    } else if menu.commands.isEmpty {
                        Text("No Matching Commands")
                            .font(.footnote)
                            .foregroundStyle(.secondaryText)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(.horizontal, 12)
                    }
                    if let ranked = menu.ranked {
                        // 輸入名稱後：單一排名清單，沒有分組標題(#45)。
                        ForEach(ranked, id: \.name) { command in
                            row(command)
                                .id(command.name)
                        }
                    }
                    ForEach(menu.sections) { section in
                        Section {
                            ForEach(section.commands, id: \.name) { command in
                                row(command)
                                    .id(command.name)
                            }
                        } header: {
                            Text(section.source.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                                // 一般大小寫，不全大寫(HIG 20.2,#35)。
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.background)
                                .accessibilityAddTraits(.isHeader)
                        }
                    }
                    if menu.isIncomplete {
                        Label("This list may be incomplete. The host took too long to list every command.", systemImage: "exclamationmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondaryText)
                            .padding(12)
                            .accessibilityIdentifier("slash.incomplete")
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, height in
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { contentHeight = min(height, Self.maximumHeight) }
            }
            .onChange(of: menu.highlighted) { _, name in
                guard let name else { return }
                proxy.scrollTo(name)
            }
        }
        .frame(height: contentHeight)
        // 不透明底：選單蓋在訊息上，半透明的 `.bar` 讓次要色文字對比不足(#35 audit)。
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Commands"))
        .accessibilityIdentifier("slash.menu")
    }

    private func row(_ command: SlashCommand) -> some View {
        Button {
            menu.pick(command)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: "/\(command.name)")
                        .font(.body.monospaced())
                        .foregroundStyle(.primary)
                    if let hint = command.argumentHint {
                        // 淡色但仍承載文字：用 `secondaryText`,不用 tertiary(對比只有約 2:1,#35、#67)。
                        Text(verbatim: hint)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondaryText)
                    }
                }
                if !command.summary.isEmpty {
                    Text(verbatim: command.summary)
                        .font(.footnote)
                        .foregroundStyle(.secondaryText)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(menu.highlighted == command.name ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.clear))
        }
        .buttonStyle(.pressableRow())
        .accessibilityLabel(Text(verbatim: "/\(command.name)"))
        .accessibilityValue(Text(verbatim: [command.argumentHint, command.summary].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")))
        .accessibilityAddTraits(menu.highlighted == command.name ? .isSelected : [])
        .accessibilityIdentifier("slash.row.\(command.name)")
    }
}

extension SlashSource {
    /// 分組標題。plugin 用它自己的名稱。
    var title: String {
        switch self {
        case .builtIn: String(localized: "Built-in")
        case .project: String(localized: "Project")
        case .user: String(localized: "User")
        case .plugin(let name): name
        case .session: String(localized: "Other Skills")
        }
    }
}
