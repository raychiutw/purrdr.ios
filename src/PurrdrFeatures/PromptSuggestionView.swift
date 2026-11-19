import PurrdrAgentFeatures
import SwiftUI

/// 輸入列上方的建議提示詞(#121、#123):Claude Code 回完一輪後輸入列裡的灰色「下一句」。
///
/// - 內容層卡片(同 slash 選單：不透明 `.background` 底 + `.separator` 邊),次要文字加圖示，看得出是「建議」
///   而不是已打好的字或 Agent 的訊息。整列是一顆按鈕(≥ 44pt),點了只填入輸入框、不送出。
/// - 長建議截斷(一般字級 2 行、AX 字級 4 行),不撐爆輸入列;鍵盤出現、空間不夠時收成一行(`isCompact`,#196)。
/// - VoiceOver 念「Suggestion: <文字>」,並提示點兩下會填入輸入框。
struct PromptSuggestionView: View {
    let suggestion: String
    var isCompact = false
    let accept: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button(action: accept) {
            Label {
                Text(verbatim: suggestion)
                    .lineLimit(isCompact ? 1 : dynamicTypeSize.isAccessibilitySize ? 4 : 2)
                    .multilineTextAlignment(.leading)
            } icon: {
                Image(systemName: "lightbulb")
            }
            .font(.subheadline)
            .foregroundStyle(.secondaryText)
            // 一行的高度(也是觸控目標的 44pt)與讓位規則的估算一致。
            .frame(maxWidth: .infinity, minHeight: ComposerKeyboardLayout.compactHeight, alignment: .leading)
            .padding(.horizontal, 12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator))
        .accessibilityLabel(Text("Suggestion: \(suggestion)"))
        .accessibilityHint(Text("Puts the suggestion in the message box without sending it."))
        .accessibilityIdentifier("conversation.suggestion")
    }
}
