import PurrdrAgentFeatures
import SwiftUI

/// 輸入列上方的建議卡(#121、#123、#240、#382):Claude Code 回完一輪後輸入列裡的灰色「下一句」。
///
/// - 與輸入卡片同一種 regular Liquid Glass(`floatingGlass`;輸入列把兩者放進同一個 `GlassEffectContainer`,間距 8pt),
///   圓角 20pt 與輸入卡片同心;「減少透明度」時退回不透明系統底加 `.separator` 邊。
/// - 「💡 建議」小標(`secondaryText`)＋內容(主要色),右側 tinted 膠囊「填入」(主色字)。整張卡是一顆按鈕(≥ 44pt),
///   點了只填入輸入框、不送出。
/// - 長建議在一般字級截成 2 行;AX 字級完整換行、「填入」換到下方(#249);鍵盤出現、空間不夠時收成一行(`isCompact`,#196),只留內容與膠囊。
/// - VoiceOver 念「建議：<內容>，填入」。
struct PromptSuggestionView: View {
    let suggestion: String
    var isCompact = false
    let accept: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    static let cornerRadius: CGFloat = 20

    /// 「填入」膠囊的淡綠底：主色疊在卡片底上的不透明度(主色字對它 ≥ 4.5:1,`AccessibleColorsTests`)。
    static let fillInTintOpacity = 0.1

    var body: some View {
        Button(action: accept) {
            // AX 字級的完整卡片：「填入」換到內容下方，小標與內容才有整寬可換行(並排時被擠到截字,#249)。
            let layout = !isCompact && dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 10))
            layout {
                VStack(alignment: .leading, spacing: 2) {
                    if !isCompact {
                        Label("Suggestion", systemImage: "lightbulb")
                            .font(.caption)
                            .foregroundStyle(.secondaryText)
                    }
                    Text(verbatim: suggestion)
                        .font(.subheadline)
                        .foregroundStyle(Color.primary)
                        .lineLimit(isCompact ? 1 : dynamicTypeSize.isAccessibilitySize ? nil : 2)
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
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .padding(.vertical, isCompact ? 0 : 6)
            .contentShape(.rect)
        }
        .buttonStyle(.pressableRow(cornerRadius: Self.cornerRadius))
        .floatingGlass(in: RoundedRectangle(cornerRadius: Self.cornerRadius))
        .accessibilityLabel(Text("Suggestion: \(suggestion), Fill In"))
        .accessibilityHint(Text("Puts the suggestion in the message box without sending it."))
        .accessibilityIdentifier("conversation.suggestion")
    }
}
