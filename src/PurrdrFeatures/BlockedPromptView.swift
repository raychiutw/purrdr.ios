import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 對話列表裡的「需要你」回答紀錄：已送達的回答(問題與選了什麼)。
/// 等待回答的問題卡改在輸入列上方的浮動層(`NeedsYouCard`,#424)。
struct BlockedPromptView: View {
    let model: ConversationModel

    var body: some View {
        if let answered = model.lastAnswer {
            AnsweredPromptView(answered: answered)
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
        case .questionChanged: String(localized: "The question changed on the host, so the answer wasn’t sent. Check it, then try again.")
        }
    }
}
