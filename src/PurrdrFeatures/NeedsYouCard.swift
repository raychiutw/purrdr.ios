import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 輸入列上方的「需要你」浮動卡(行為規格 F8、#424;與建議卡同一層、同一個玻璃容器)。
///
/// - Liquid Glass(`floatingGlass`;減少透明度時退回不透明底加細邊)。內容太高時卡片內捲動，不把對話擠掉。
/// - 選項列固定為「標籤 + 22×22pt 附屬位置」:送出中只在附屬位置放 small 轉圈，列高不變(含動態字級放大)。
/// - 按下的選項以強調色淡底，其他選項停用變淡;VoiceOver 念出「送出中」與停用(`PromptOptionState`)。
/// - 送出失敗在卡片頂端顯示錯誤(alert 角色，會朗讀)，選項恢復可再選。
/// - 「拒絕」不套 destructive 紅色;編號 10 以上的選項停用，並說明到終端機回答(R-Q04)。
/// - Claude 的「Type something.」不送按鍵，改用底部輸入框打自訂答案(#120)。
struct NeedsYouCard: View {
    let model: ConversationModel
    /// 卡片最高 300pt、超過在卡片內捲動;不隨字級放大，否則 AX 字級下卡片會吃掉整個畫面。
    private let maximumHeight = 300.0
    @State private var contentHeight = 0.0

    static let cornerRadius: CGFloat = 24
    /// 選項列右側附屬位置的邊長(轉圈、鍵盤圖示共用，列高不隨送出狀態改變)。
    static let accessorySize: CGFloat = 22
    /// 按下的選項的淡底不透明度(主色疊在卡片底上，主要色字對它 ≥ 4.5:1)。
    static let pressedFillOpacity = 0.22
    /// 每個選項是獨立的圓角底(設計稿畫板 29:圓角 14、列高 48、列距 6)。
    static let optionCornerRadius: CGFloat = 14
    static let optionSpacing: CGFloat = 6
    static let optionHeight: CGFloat = 48

    var body: some View {
        if let prompt = model.prompt {
            ScrollView {
                content(prompt)
                    .onGeometryChange(for: Double.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: contentHeight > 0 ? min(contentHeight, maximumHeight) : nil)
            .floatingGlass(in: RoundedRectangle(cornerRadius: Self.cornerRadius))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("prompt.card")
        }
    }

    private func content(_ prompt: BlockedPrompt) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(prompt.question ?? String(localized: "The agent is waiting for you."))
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(AgentStatus.blocked.tone.style)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Needs You: \(prompt.question ?? String(localized: "The agent is waiting for you."))"))
            .accessibilityIdentifier("prompt.question")

            // 送出失敗的錯誤接在題目下面、選項上面(設計稿畫板 29)。
            if let notice = model.answerNotice {
                noticeBanner(notice)
            }
            if prompt.detailsOffscreen {
                Label("The start of this prompt is off screen. Check the terminal for the details.", systemImage: "terminal")
                    .font(.footnote)
                    .foregroundStyle(.secondaryText)
            }
            if let details = prompt.details {
                PromptDetailsView(details: details)
            }
            // 唯讀裝置(#60)不顯示選項;說明只在頂部橫幅(#349,同一資訊只出現一處)。
            if !model.isReadOnly {
                choices(prompt)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 送出失敗的錯誤(alert 角色):在題目下方，出現時朗讀。
    private func noticeBanner(_ notice: AnswerNotice) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label {
                Text(notice.text)
                    .foregroundStyle(Color.primary)
            } icon: {
                Image(systemName: ErrorLabel.symbolName)
                    .foregroundStyle(.red)
            }
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                model.dismissAnswerNotice()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondaryText)
            .accessibilityLabel(Text("Dismiss"))
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("prompt.notice")
        .onAppear { AccessibilityNotification.Announcement(notice.text).post() }
    }

    @ViewBuilder
    private func choices(_ prompt: BlockedPrompt) -> some View {
        switch prompt.kind {
        case .menu, .trust:
            OptionGroup {
                ForEach(prompt.options) { option in
                    optionRow(option)
                }
                if prompt.isMultiSelect {
                    answerRow(.continueMultiSelect, title: String(localized: "Continue"), identifier: "prompt.continue")
                }
            }
            if prompt.options.contains(where: { ($0.number ?? 0) > 9 }) {
                Text("Options above 9 can’t be entered from here. Answer them in the terminal.")
                    .font(.footnote)
                    .foregroundStyle(.secondaryText)
            }
        case .filePicker:
            Text("Codex has its file picker open. Close it here, or choose a file in the terminal.")
                .font(.subheadline)
                .foregroundStyle(.secondaryText)
            OptionGroup {
                answerRow(.closePicker, title: String(localized: "Close File Picker"), identifier: "prompt.closePicker")
            }
        case .unrecognized:
            Text("Couldn’t read the choices. These send common answers; check the terminal if you’re not sure.")
                .font(.subheadline)
                .foregroundStyle(.secondaryText)
            // 主機服務太舊、讀不了畫面(#303)的說明只在頂部橫幅(#349)。
            OptionGroup {
                answerRow(.generic(.confirm), title: String(localized: "Confirm (Return)"), identifier: "prompt.generic.confirm")
                answerRow(.generic(.one), title: String(localized: "Choose 1"), identifier: "prompt.generic.one")
                answerRow(.generic(.two), title: String(localized: "Choose 2"), identifier: "prompt.generic.two")
                answerRow(.generic(.escape), title: String(localized: "Cancel (Esc)"), identifier: "prompt.generic.escape")
            }
        }
    }

    private func optionRow(_ option: PromptOption) -> some View {
        let state = model.optionState(for: option)
        let typesAnswer = model.isTypedAnswerOption(option)
        return Button {
            if typesAnswer {
                model.beginTypedAnswer(option)
            } else {
                Task { await model.answer(.option(option)) }
            }
        } label: {
            OptionRowLabel(title: option.label, checked: option.checked, state: state) {
                if typesAnswer, state != .sending {
                    Image(systemName: model.typedAnswer == option ? "keyboard.fill" : "keyboard")
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.pressableRow(cornerRadius: NeedsYouCard.optionCornerRadius))
        .disabled(state == .disabled)
        .accessibilityLabel(optionAccessibilityLabel(option))
        .accessibilityValue(state == .sending ? Text("Sending") : Text(verbatim: ""))
        .accessibilityHint(optionHint(option, typesAnswer: typesAnswer))
        .accessibilityIdentifier("prompt.option.\(option.id)")
    }

    private func answerRow(_ answer: PromptAnswer, title: String, identifier: String) -> some View {
        let state: PromptOptionState = model.answerInFlight == answer ? .sending : model.canAnswer(answer) ? .available : .disabled
        return Button {
            Task { await model.answer(answer) }
        } label: {
            OptionRowLabel(title: title, checked: nil, state: state) {}
        }
        .buttonStyle(.pressableRow(cornerRadius: NeedsYouCard.optionCornerRadius))
        .disabled(state == .disabled)
        .accessibilityValue(state == .sending ? Text("Sending") : Text(verbatim: ""))
        .accessibilityIdentifier(identifier)
    }

    private func optionHint(_ option: PromptOption, typesAnswer: Bool) -> Text {
        if typesAnswer { return Text("Type your answer in the message field.") }
        return (option.number ?? 0) > 9 ? Text("Answer this option in the terminal.") : Text(verbatim: "")
    }

    private func optionAccessibilityLabel(_ option: PromptOption) -> Text {
        let checked = option.checked.map { $0 ? String(localized: "Selected") : String(localized: "Not Selected") }
        let parts = [option.label, checked].compactMap { $0 }
        return Text(verbatim: parts.joined(separator: ", "))
    }
}

/// 一組選項：每個選項是獨立的圓角底、列距 6pt(設計稿畫板 29)。
private struct OptionGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: NeedsYouCard.optionSpacing) {
            content
        }
    }
}

/// 選項列：標籤 + 固定 22×22pt 的附屬位置。送出中只在附屬位置放 small 轉圈，列高不變。
private struct OptionRowLabel<Accessory: View>: View {
    let title: String
    let checked: Bool?
    let state: PromptOptionState
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if let checked {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .accessibilityHidden(true)
            }
            Text(verbatim: title)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            ZStack {
                if state == .sending {
                    ProgressView().controlSize(.small)
                } else {
                    accessory
                }
            }
            .frame(width: NeedsYouCard.accessorySize, height: NeedsYouCard.accessorySize)
        }
        .foregroundStyle(Color.primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, minHeight: NeedsYouCard.optionHeight, alignment: .leading)
        .background(
            state == .sending ? AnyShapeStyle(.softAccentFill(opacity: NeedsYouCard.pressedFillOpacity)) : AnyShapeStyle(.fill.tertiary),
            in: RoundedRectangle(cornerRadius: NeedsYouCard.optionCornerRadius))
        .contentShape(.rect)
    }
}
