import PurrdrAgentFeatures
import SwiftUI

/// 輸入列上方的建議卡(#121、#123、#240):Claude Code 回完一輪後輸入列裡的灰色「下一句」。
///
/// - 內容層卡片(同 slash 選單：不透明 `.background` 底 + `.separator` 邊):「💡 建議」小標＋內容，右側淡綠底的
///   「填入」膠囊。整張卡是一顆按鈕(≥ 44pt),點了只填入輸入框、不送出。
/// - 長建議截斷(一般字級 2 行、AX 字級 4 行),不撐爆輸入列;鍵盤出現、空間不夠時收成一行(`isCompact`,#196),只留內容與膠囊。
/// - VoiceOver 念「建議：<內容>，填入」。
struct PromptSuggestionView: View {
    let suggestion: String
    var isCompact = false
    let accept: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// 「填入」膠囊的淡綠底：主色疊在卡片底上的不透明度(主色字對它 ≥ 4.5:1,`AccessibleColorsTests`)。
    static let fillInTintOpacity = 0.1

    var body: some View {
        Button(action: accept) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    if !isCompact {
                        Label("Suggestion", systemImage: "lightbulb")
                            .font(.caption)
                            .foregroundStyle(.secondaryText)
                    }
                    Text(verbatim: suggestion)
                        .font(.subheadline)
                        .foregroundStyle(Color.primary)
                        .lineLimit(isCompact ? 1 : dynamicTypeSize.isAccessibilitySize ? 4 : 2)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("Fill In")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(.softAccentFill(opacity: Self.fillInTintOpacity), in: Capsule())
            }
            // 一行的高度(也是觸控目標的 44pt)與讓位規則的估算一致。
            .frame(maxWidth: .infinity, minHeight: ComposerKeyboardLayout.compactHeight, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, isCompact ? 0 : 6)
            .contentShape(.rect)
        }
        .buttonStyle(.pressableRow(cornerRadius: 16))
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator))
        .accessibilityLabel(Text("Suggestion: \(suggestion), Fill In"))
        .accessibilityHint(Text("Puts the suggestion in the message box without sending it."))
        .accessibilityIdentifier("conversation.suggestion")
    }
}
