import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 導覽列中間的標題膠囊(#380,原型 Header):兩行,高度仿原生相簿膠囊。
/// 第一行是 workspace 名稱加 `chevron.down`(可點);第二行是權限模式(非一般才有)、狀態與主機名,主機名過長從尾端截斷。
/// 點開是面板(`ConversationStatusSheet`):context、模型、待辦、背景子 Agent、做完再送與權限模式選項。
struct ConversationTitleView: View {
    let title: String
    let header: ConversationHeader
    @Bindable var model: ConversationModel

    /// 膠囊最小高度:兩行字加上內距,比單行標題高(原生相簿膠囊約 48pt)。
    private static let minimumHeight: CGFloat = 48

    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondaryText)
                    .accessibilityHidden(true)
            }
            ConversationHeaderLine(header: header)
        }
        // 標題膠囊(#348 A1):浮在內容上的玻璃,內容從底下捲過去;減少透明度時改不透明底。
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(minHeight: Self.minimumHeight)
        .floatingGlass(in: Capsule())
        // 點標題由下方升起面板(#380):一律打得開。
        .contentShape(Capsule())
        .onTapGesture { model.showsStatusSheet = true }
        .accessibilityAction(named: Text("Show Status")) { model.showsStatusSheet = true }
    }
}

struct ConversationHeaderLine: View {
    let header: ConversationHeader

    var body: some View {
        // 寬度不夠時依序試:完整 → 主機名截斷到固定寬 → 拿掉主機名 → 只剩狀態(權限模式與狀態比主機名重要)。
        ViewThatFits(in: .horizontal) {
            line(host: .full)
            line(host: .truncated)
            line(host: .none)
            line(host: .none, compactBadge: true)
            statusLabel
        }
        .font(.caption)
        .foregroundStyle(.secondaryText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(header.lineAccessibilityText))
        .accessibilityHint(Text("Shows context and permission mode."))
        // 只是文字、不能點(#35:沒有這個 trait 時 audit 把它當成觸控目標，報 hit region 太小)。
        .accessibilityAddTraits(.isStaticText)
        .accessibilityIdentifier("conversation.header")
    }

    private enum HostDisplay { case full, truncated, none }

    private func line(host: HostDisplay, compactBadge: Bool = false) -> some View {
        HStack(spacing: 5) {
            if let badge = header.permissionBadge {
                PermissionBadgeView(badge: badge, isCompact: compactBadge)
                separator
            }
            statusLabel
            if host != .none, !header.segments.isEmpty {
                separator
                Text(verbatim: header.segments.joined(separator: " · "))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: host == .truncated ? 72 : nil)
                    .fixedSize(horizontal: host == .full, vertical: false)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var separator: some View {
        Text(verbatim: "·").fixedSize()
    }

    /// 狀態符號沿用列表那組(`AgentStatus.symbol`);連線中斷是 `wifi.slash`,不混進 Agent 狀態。
    private var statusLabel: some View {
        HStack(spacing: 3) {
            if let status = header.agentStatus {
                Image(systemName: status.symbol)
                    .foregroundStyle(status.tone.style)
            } else {
                Image(systemName: "wifi.slash")
            }
            Text(header.status.title)
                .lineLimit(1)
        }
    }
}

/// 膠囊第二行的權限模式:符號加名稱;略過權限是橙色警示(`exclamationmark.shield`),面板外也看得到。
private struct PermissionBadgeView: View {
    let badge: ConversationHeader.PermissionBadge
    /// 放不下時只留符號(略過權限的橙色警示仍看得到)。
    var isCompact = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: badge.mode.symbol)
                .foregroundStyle(badge.isWarning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondaryText))
            if !isCompact {
                Text(verbatim: badge.mode.displayName)
                    .lineLimit(1)
            }
        }
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
