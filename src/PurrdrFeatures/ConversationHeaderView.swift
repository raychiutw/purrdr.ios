import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 8pt 單色狀態點。停止列(`StopBar`)的工作中圓點用這個元件。
/// 點是裝飾:不進 accessibility tree(狀態由文字與 VoiceOver 標籤表達)。
struct StatusDot: View {
    static let diameter: CGFloat = 8
    let tone: StatusTone

    var body: some View {
        Circle()
            .fill(tone.style)
            .frame(width: Self.diameter, height: Self.diameter)
            .dimsWhenWindowInactive()
            .accessibilityHidden(true)
    }
}

/// 對話底部的即時預覽(F5.11):工作中擷取到的散文(次要色)。狀態字、經過時間與停止在輸入卡片上方的工作中膠囊(`StopBar`),
/// 畫面上只有一個工作中指示(原型 purrdr-screens 定案版)。內容層，不用玻璃。
struct WorkingIndicatorView: View {
    let preview: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if let preview {
            Text(preview)
                .font(.subheadline)
                .foregroundStyle(.secondaryText)
                // AX 字級不限行數(DESIGN.md:支援到 AX5 不截斷,#35)。
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("conversation.livePreview")
        } else {
            // 工作中那一列(`ChatListRowPlan.workingID`)要在;沒有預覽時不佔空間。
            Color.clear.frame(height: 1).accessibilityHidden(true)
        }
    }
}
