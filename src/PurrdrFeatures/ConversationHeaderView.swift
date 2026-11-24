import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 導覽列中間的兩行標題膠囊(#514,原型 Main)。
/// 第一行 Tab 名稱(過長以 … 截斷);第二行「電腦圖示 主機名稱 · 8pt 狀態點 狀態文字」,權限模式不是一般時尾端加符號與短名
/// (略過權限保留橘色盾牌)。標題不可點、沒有下拉箭頭(功能在右側「⋯」選單);大字級時兩行各自截斷,不擠掉兩側的鈕。
struct ConversationTitleView: View {
    let title: String
    let header: ConversationHeader

    var body: some View {
        VStack(spacing: 1) {
            Text(verbatim: header.capsuleName.isEmpty ? title : header.capsuleName)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
            secondLine
        }
        // 標題膠囊(#348 A1):浮在內容上的玻璃,內容從底下捲過去;減少透明度時改不透明底。
        .padding(.horizontal, 16)
        .frame(minHeight: TopBarMetrics.titleCapsuleHeight)
        .floatingGlass(in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: header.accessibilityText))
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("conversation.header")
    }

    private var secondLine: some View {
        let line = header.secondLine
        return HStack(spacing: 4) {
            if !line.hostNames.isEmpty {
                Image(systemName: "desktopcomputer")
                    .accessibilityHidden(true)
                Text(verbatim: line.hostNames.joined(separator: ", "))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(verbatim: "·")
                    .accessibilityHidden(true)
            }
            // 狀態與模式比主機名稱晚被截斷:名稱先縮。
            StatusDot(tone: header.status.tone)
            Text(verbatim: line.statusTitle)
                .lineLimit(1)
                .layoutPriority(1)
            if let badge = line.badge {
                Text(verbatim: "·")
                    .accessibilityHidden(true)
                HStack(spacing: 3) {
                    if badge.isWarning {
                        Image(systemName: badge.mode.symbol)
                            .foregroundStyle(Color.orange)
                            .accessibilityHidden(true)
                    }
                    Text(verbatim: badge.mode.displayName)
                        .lineLimit(1)
                }
                .layoutPriority(1)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondaryText)
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
            // 工作中那一列(`ChatListRowPlan.workingID`)要在;沒有預覽時不佔空間。
            Color.clear.frame(height: 1).accessibilityHidden(true)
        }
    }
}
