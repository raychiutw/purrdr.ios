import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 對話中的「需要你」提示卡(行為規格 F8;DESIGN.md「agent 卡住時，選項以卡片放在該則提問下方」;HIG 20.7)。
///
/// - 內容層：不用 Liquid Glass;選項是同尺寸的灰色 bordered 按鈕，不編號、不標預設選項(#271,原型 purrdr-screens 定案版)。
/// - 「拒絕」不套 destructive 紅色。
/// - 編號 10 以上的選項停用，並說明到終端機回答(R-Q04)。
/// - 作答後選項全部停用、被點的列轉圈;送達後以文字顯示選了什麼(不只改顏色)。
/// - Claude 的「Type something.」不送按鍵，改用底部輸入框打自訂答案(#120,`ConversationModel.beginTypedAnswer`)。
struct BlockedPromptView: View {
    let model: ConversationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let answered = model.lastAnswer {
                AnsweredPromptView(answered: answered)
            }
            if let prompt = model.prompt {
                card(prompt)
            }
        }
    }

    private func card(_ prompt: BlockedPrompt) -> some View {
        VStack(alignment: .leading, spacing: 12) {
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

            if prompt.detailsOffscreen {
                Label("The start of this prompt is off screen. Check the terminal for the details.", systemImage: "terminal")
                    .font(.footnote)
                    .foregroundStyle(.secondaryText)
            }
            if let details = prompt.details {
                PromptDetailsView(details: details)
            }
            if model.isReadOnly {
                // 唯讀裝置(#60):不顯示選項，說明到主機或可寫入的裝置回答。
                Label("This device is paired read-only. Answer on the host or from a device that can send.", systemImage: "lock")
                    .font(.footnote)
                    .foregroundStyle(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("prompt.readOnly")
            } else {
                choices(prompt)
            }
            if let notice = model.answerNotice {
                HStack(alignment: .firstTextBaseline) {
                    Label(notice.text, systemImage: "exclamationmark.triangle")
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
                .accessibilityIdentifier("prompt.notice")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("prompt.card")
    }

    @ViewBuilder
    private func choices(_ prompt: BlockedPrompt) -> some View {
        switch prompt.kind {
        case .menu, .trust:
            VStack(spacing: 8) {
                ForEach(prompt.options) { option in
                    optionButton(option, in: prompt)
                }
                if prompt.isMultiSelect {
                    answerButton(.continueMultiSelect, title: String(localized: "Continue"), identifier: "prompt.continue")
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
            answerButton(.closePicker, title: String(localized: "Close File Picker"), identifier: "prompt.closePicker")
        case .unrecognized:
            Text("Couldn’t read the choices. These send common answers; check the terminal if you’re not sure.")
                .font(.subheadline)
                .foregroundStyle(.secondaryText)
            if let update = model.screenUpdateRequiredMessage {
                // HTTPS 主機的主機服務太舊、讀不了畫面(#303):說明更新後才看得到選項。
                Label(update, systemImage: "arrow.down.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("prompt.hostServiceUpdate")
            }
            VStack(spacing: 8) {
                answerButton(.generic(.confirm), title: String(localized: "Confirm (Return)"), identifier: "prompt.generic.confirm")
                answerButton(.generic(.one), title: String(localized: "Choose 1"), identifier: "prompt.generic.one")
                answerButton(.generic(.two), title: String(localized: "Choose 2"), identifier: "prompt.generic.two")
                answerButton(.generic(.escape), title: String(localized: "Cancel (Esc)"), identifier: "prompt.generic.escape")
            }
        }
    }

    private func optionButton(_ option: PromptOption, in prompt: BlockedPrompt) -> some View {
        let answer = PromptAnswer.option(option)
        let typesAnswer = model.isTypedAnswerOption(option)
        return Button {
            if typesAnswer {
                model.beginTypedAnswer(option)
            } else {
                Task { await model.answer(answer) }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let checked = option.checked {
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .accessibilityHidden(true)
                }
                Text(verbatim: option.label)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if model.isAnswering(option) {
                    ProgressView()
                } else if typesAnswer {
                    Image(systemName: model.typedAnswer == option ? "keyboard.fill" : "keyboard")
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        }
        .optionStyle()
        .disabled(typesAnswer ? !model.canBeginTypedAnswer(option) : !model.canAnswer(answer))
        .accessibilityLabel(optionAccessibilityLabel(option))
        .accessibilityHint(optionHint(option, typesAnswer: typesAnswer))
        .accessibilityIdentifier("prompt.option.\(option.id)")
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

    private func answerButton(_ answer: PromptAnswer, title: String, identifier: String) -> some View {
        Button {
            Task { await model.answer(answer) }
        } label: {
            HStack {
                Text(verbatim: title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if model.answerInFlight == answer {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        }
        .optionStyle()
        .disabled(!model.canAnswer(answer))
        .accessibilityIdentifier(identifier)
    }
}

private extension View {
    /// 同一組選項同尺寸、同樣式(#271,原型 purrdr-screens 定案版):灰色圓角長方形，不編號、不標預設選項。
    /// 圓角長方形選項卡(#93):膠囊形像按鈕列，多行文字也不好讀。
    func optionStyle() -> some View {
        // 文字用主要色：bordered 預設是 tint 字配淡 tint 底，對比約 4:1、AX 字級下更低(#35 audit)。
        buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: PromptOptionStyle.cornerRadius))
            .foregroundStyle(Color.primary)
    }
}

/// 要批准的是什麼：標題、摘要、內容(等寬、橫捲不換行、超過 8 行折疊)、附註(注意色)。
struct PromptDetailsView: View {
    let details: PromptDetails
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = details.title {
                Text(verbatim: title)
                    .font(.subheadline.bold())
            }
            if let summary = details.summary {
                Text(verbatim: summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondaryText)
            }
            if !details.content.isEmpty {
                let lines = expanded ? details.content : Array(details.content.prefix(8))
                ScrollView(.horizontal) {
                    Text(verbatim: lines.joined(separator: "\n"))
                        .font(.callout.monospaced())
                        .fixedSize()
                        .textSelection(.enabled)
                        .padding(8)
                }
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 8))
                .contextMenu {
                    Button("Copy", systemImage: "doc.on.doc") {
                        Clipboard.copy(details.content.joined(separator: "\n"))
                    }
                }
                .accessibilityIdentifier("prompt.content")
                if details.content.count > 8 {
                    Button(expanded ? "Show Less" : "Show All \(details.content.count) Lines") {
                        expanded.toggle()
                    }
                    .font(.footnote)
                }
            }
            if let note = details.note {
                // 系統橙對卡片底約 2:1,只上圖示(#237)。
                Label {
                    Text(verbatim: note)
                        .foregroundStyle(Color.primary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(StatusTone.attention.style)
                }
                .font(.footnote)
            }
        }
    }
}

/// 已送達的回答：問題與選了什麼。
struct AnsweredPromptView: View {
    let answered: AnsweredPrompt

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                if let question = answered.question {
                    Text(verbatim: question)
                        .font(.footnote)
                        .foregroundStyle(.secondaryText)
                }
                Text("You chose: \(answered.choice)")
                    .font(.subheadline)
            }
        } icon: {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("prompt.answered")
    }
}

extension AnswerNotice {
    var text: String {
        switch self {
        case .mayNotHaveArrived: String(localized: "The answer may not have arrived. Check the agent, then try again.")
        case .sendFailed: String(localized: "Couldn’t send the answer to the host.")
        }
    }
}
