import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// slash 指令開出的面板(`/model`、`/effort`…)在聊天內的原生卡片(#45、行為規格 F9.4;HIG 20.6、20.7)。
///
/// - 內容層：和「需要你」的提示卡同樣的背景，不用 Liquid Glass。
/// - 選項列：目前使用中以勾號 + 文字標示(不只靠顏色),游標所在列以填色高亮;點選項只移動游標(送方向鍵),
///   由面板自己的動作鈕確認。**永不送數字**(數字在模型選擇器會直接存成預設)。
/// - effort 層級攤開成直排的勾選列(#313),目前那層打勾;‹ › 調整送 ←/→。
/// - 動作鈕取自面板的提示行(agent 的原文，不翻譯);確認鍵(Enter)是 prominent,取消(Esc)放最後且中性。
struct SlashPanelCard: View {
    let model: ConversationModel
    let panel: SlashPanel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title = panel.title {
                Text(verbatim: title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            if !panel.notes.isEmpty {
                ScrollView {
                    Text(verbatim: panel.notes.joined(separator: "\n"))
                        .font(.footnote)
                        .foregroundStyle(.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                .fixedSize(horizontal: false, vertical: true)
            }
            if !panel.options.isEmpty {
                options
            }
            if let slider = panel.slider {
                levels(slider)
            }
            if let adjustment = panel.adjustment {
                adjuster(adjustment)
            }
            actions
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        .disabled(model.isOperatingPanel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("panel.card")
    }

    // MARK: - 選項

    private var options: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(panel.options) { option in
                    optionRow(option)
                }
            }
        }
        .frame(maxHeight: 240)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("panel.options")
    }

    private func optionRow(_ option: SlashPanelOption) -> some View {
        Button {
            operate(.select(option))
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: option.label)
                        .foregroundStyle(.primary)
                    if let detail = option.detail {
                        Text(verbatim: detail)
                            .font(.footnote)
                            .foregroundStyle(.secondaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if option.isCurrent {
                    Label("Current", systemImage: "checkmark")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .background(option.isCursor ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(panel.keys(for: .select(option)) == nil)
        .accessibilityLabel(Text(verbatim: [option.label, option.detail].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityValue(option.isCurrent ? Text("Current") : Text(verbatim: ""))
        .accessibilityAddTraits(option.isCursor ? .isSelected : [])
        .accessibilityHint(Text("Moves the panel’s selection to this option."))
        .accessibilityIdentifier("panel.option.\(option.index)")
    }

    // MARK: - effort

    /// 層級攤開成直排的勾選列(#313),樣式同上面的選項列;目前的層級打勾。
    private func levels(_ slider: SlashPanelSlider) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(slider.levels.enumerated()), id: \.offset) { index, level in
                levelRow(level, isCurrent: slider.current == index) { operate(.level(index)) }
            }
        }
        .disabled(slider.current == nil)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Level"))
        .accessibilityIdentifier("panel.levels")
    }

    private func levelRow(_ level: String, isCurrent: Bool, select: @escaping () -> Void) -> some View {
        Button(action: select) {
            HStack(spacing: 8) {
                Text(verbatim: level)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: level))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private func adjuster(_ text: String) -> some View {
        HStack(spacing: 8) {
            adjustButton(.left)
            Text(verbatim: text)
                .font(.subheadline)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("panel.adjustment")
            adjustButton(.right)
        }
    }

    private func adjustButton(_ direction: SlashPanel.Direction) -> some View {
        Button {
            operate(.adjust(direction))
        } label: {
            Image(systemName: direction == .left ? "chevron.left" : "chevron.right")
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel(direction == .left ? Text("Decrease") : Text("Increase"))
        .accessibilityIdentifier(direction == .left ? "panel.adjust.left" : "panel.adjust.right")
    }

    // MARK: - 動作

    private var actions: some View {
        // 取消(Esc)放最後。
        let ordered = panel.actions.filter { !$0.isCancel } + panel.actions.filter(\.isCancel)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { actionButtons(ordered) }
            VStack(spacing: 8) { actionButtons(ordered) }
        }
    }

    @ViewBuilder
    private func actionButtons(_ actions: [SlashPanelAction]) -> some View {
        ForEach(actions, id: \.self) { action in
            let button = Button {
                operate(.action(action))
            } label: {
                Text(verbatim: title(of: action))
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .accessibilityIdentifier("panel.action.\(action.key)")
            if action.key == "enter" {
                button.filledProminentButtonStyle()
            } else {
                // 文字用主要色(取消要中性):bordered 預設是 tint 字配淡 tint 底，在卡片填色上對比不到 4.5:1(#67 audit)。
                button.buttonStyle(.bordered)
                    .foregroundStyle(Color.primary)
            }
        }
    }

    /// 提示行的原文(首字大寫);面板沒有提示行時依按鍵給標籤。
    private func title(of action: SlashPanelAction) -> String {
        if let label = action.label, let first = label.first {
            return first.uppercased() + label.dropFirst()
        }
        switch action.key {
        case "esc": return String(localized: "Cancel")
        default: return String(localized: "Confirm")
        }
    }

    private func operate(_ input: SlashPanel.Input) {
        Task { await model.operatePanel(input) }
    }
}
