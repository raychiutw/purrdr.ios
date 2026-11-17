import PurrdrCore
import SwiftUI

/// 對話中的「需要你」提示卡(行為規格 F8;DESIGN.md「agent 卡住時，選項以卡片放在該則提問下方」;HIG 20.7)。
///
/// - 內容層：不用 Liquid Glass;選項是一般 bordered／borderedProminent 按鈕，同一組同尺寸，建議選項以樣式區分。
/// - 「拒絕」不套 destructive 紅色;會結束 agent 的選項不設為建議(`PromptOptionStyle`)。
/// - 編號 10 以上顯示但停用，並說明到終端機回答(R-Q04)。
/// - 作答後選項全部停用、被點的列轉圈;送達後以文字顯示選了什麼(不只改顏色)。
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
                    .foregroundStyle(.tint)
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
            choices(prompt)
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
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
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
        return Button {
            Task { await model.answer(answer) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let number = option.number {
                    Text(verbatim: "\(number).")
                        .monospacedDigit()
                }
                if let checked = option.checked {
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .accessibilityHidden(true)
                }
                Text(verbatim: option.label)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if model.answerInFlight == answer {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        }
        .optionStyle(prominent: PromptOptionStyle.isRecommended(option))
        .disabled(!model.canAnswer(answer))
        .accessibilityLabel(optionAccessibilityLabel(option))
        .accessibilityHint((option.number ?? 0) > 9 ? Text("Answer this option in the terminal.") : Text(verbatim: ""))
        .accessibilityIdentifier("prompt.option.\(option.id)")
    }

    private func optionAccessibilityLabel(_ option: PromptOption) -> Text {
        let checked = option.checked.map { $0 ? String(localized: "Selected") : String(localized: "Not Selected") }
        let parts = [option.number.map(String.init), option.label, checked].compactMap { $0 }
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
        .optionStyle(prominent: false)
        .disabled(!model.canAnswer(answer))
        .accessibilityIdentifier(identifier)
    }
}

private extension View {
    /// 同一組選項同尺寸;建議選項用 prominent 樣式而非大小區分(HIG 20.7)。
    @ViewBuilder
    func optionStyle(prominent: Bool) -> some View {
        if prominent {
            filledProminentButtonStyle()
        } else {
            // 文字用主要色：bordered 預設是 tint 字配淡 tint 底，對比約 4:1、AX 字級下更低(#35 audit)。
            buttonStyle(.bordered)
                .foregroundStyle(Color.primary)
        }
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
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
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
                Label {
                    Text(verbatim: note)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.footnote)
                .foregroundStyle(.orange)
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
                .foregroundStyle(.green)
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
