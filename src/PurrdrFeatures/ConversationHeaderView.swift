import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 導覽列中間：workspace 名稱與下一行的狀態、主機名、context 百分比(#270、#349)。
///
/// 資訊行寧可整段拿掉也不截斷(`ViewThatFits` 依序試 `displayVariants`);VoiceOver 念完整內容。
struct ConversationTitleView: View {
    let title: String
    let header: ConversationHeader
    @Bindable var model: ConversationModel

    var body: some View {
        VStack(spacing: 1) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            ConversationHeaderLine(header: header)
        }
        // 標題膠囊(#348 A1):浮在內容上的玻璃,內容從底下捲過去;減少透明度時改不透明底。
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .floatingGlass(in: Capsule())
        // 點標題由下方升起狀態 sheet(#349):context、待辦、背景子 Agent、做完再送開關;一律打得開。
        .contentShape(Rectangle())
        .onTapGesture { model.showsStatusSheet = true }
        .accessibilityAction(named: Text("Show Status")) { model.showsStatusSheet = true }
    }
}

struct ConversationHeaderLine: View {
    let header: ConversationHeader

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(header.status.tone.style)
                .frame(width: 7, height: 7)
                .opacity(header.status == .offline ? 0.5 : 1)
            ViewThatFits(in: .horizontal) {
                ForEach(header.displayVariants, id: \.self) { text in
                    Text(text)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondaryText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(([header.lineAccessibilityText] + [header.progressText].compactMap { $0 }).joined(separator: ", ")))
        // 只是文字、不能點(#35:沒有這個 trait 時 audit 把它當成觸控目標，報 hit region 太小)。
        .accessibilityAddTraits(.isStaticText)
        .accessibilityIdentifier("conversation.header")
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
