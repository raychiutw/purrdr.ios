import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 導覽列中間的標題膠囊(#476,原型 Header):單行 44pt。
/// 依序是 8pt 單色狀態點(需要你橘、工作中主色、其他灰)、Tab 名稱(過長以 … 截斷)、權限模式(非一般才有;
/// 略過權限前面保留橘色盾牌)。沒有下拉箭頭與狀態文字,狀態靠點與 VoiceOver 標籤。
/// 點開是面板(`ConversationStatusSheet`):context、模型、待辦、背景子 Agent、做完再送與權限模式選項。
struct ConversationTitleView: View {
    let title: String
    let header: ConversationHeader
    @Bindable var model: ConversationModel

    var body: some View {
        HStack(spacing: 8) {
            if let status = header.agentStatus {
                StatusDot(tone: status.tone)
            } else {
                StatusDot(tone: header.status.tone)
            }
            Text(verbatim: header.capsuleName.isEmpty ? title : header.capsuleName)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
            if let badge = header.permissionBadge {
                HStack(spacing: 4) {
                    if badge.isWarning {
                        Image(systemName: badge.mode.symbol)
                            .foregroundStyle(Color.orange)
                            .accessibilityHidden(true)
                    }
                    Text(verbatim: badge.mode.displayName)
                        .lineLimit(1)
                }
                .font(.subheadline)
                .foregroundStyle(.secondaryText)
                // 名稱先被截斷,模式一直看得到。
                .layoutPriority(1)
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        // 標題膠囊(#348 A1):浮在內容上的玻璃,內容從底下捲過去;減少透明度時改不透明底。
        .padding(.horizontal, 16)
        .frame(minHeight: TopBarMetrics.titleCapsuleHeight)
        .floatingGlass(in: Capsule())
        // 點標題由下方升起面板(#380):一律打得開。
        .contentShape(Capsule())
        .onTapGesture { model.showsStatusSheet = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: header.accessibilityText))
        .accessibilityHint(Text("Shows usage and permission mode."))
        .accessibilityAddTraits([.isButton, .isHeader])
        .accessibilityIdentifier("conversation.header")
        .accessibilityAction(named: Text("Show Status")) { model.showsStatusSheet = true }
    }
}

/// 8pt 單色狀態點。標題膠囊與停止列(`StopBar`)的工作中圓點共用這一個元件與尺寸(#476)。
/// 點是裝飾:不進 accessibility tree(狀態由文字與 VoiceOver 標籤表達)。
struct StatusDot: View {
    static let diameter: CGFloat = 8
    let tone: StatusTone

    var body: some View {
        Circle()
            .fill(tone.style)
            .frame(width: Self.diameter, height: Self.diameter)
            .accessibilityHidden(true)
    }
}

extension AgentPermissionMode {
    /// 膠囊與選項用的符號。
    var symbol: String {
        switch self {
        case .normal: "hand.raised"
        case .acceptEdits: "chevron.forward.2"
        case .plan: "list.bullet.clipboard"
        case .bypassPermissions: "exclamationmark.shield"
        case .auto: "wand.and.sparkles"
        case .dontAsk: "hand.raised.slash"
        }
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
            // 捲動跟隨的目標列(`ConversationFollowTarget.workingRowID`)要在;沒有預覽時不佔空間。
            Color.clear.frame(height: 1).accessibilityHidden(true)
        }
    }
}
