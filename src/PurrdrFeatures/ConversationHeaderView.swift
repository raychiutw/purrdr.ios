import PurrdrCore
import SwiftUI

/// 導覽列中間：標題與下一行的資訊(F5.7;#44)。
///
/// 資訊行寧可整段拿掉也不截斷(`ViewThatFits` 依序試 `displayVariants`);VoiceOver 念完整內容。
struct ConversationTitleView: View {
    let title: String
    let header: ConversationHeader

    var body: some View {
        VStack(spacing: 1) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            ConversationHeaderLine(header: header)
        }
    }
}

struct ConversationHeaderLine: View {
    let header: ConversationHeader

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(header.status.color)
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
        .accessibilityLabel(Text(header.accessibilityText))
        // 只是文字、不能點(#35:沒有這個 trait 時 audit 把它當成觸控目標，報 hit region 太小)。
        .accessibilityAddTraits(.isStaticText)
        .accessibilityIdentifier("conversation.header")
    }
}

extension ConversationHeader.Status {
    /// 與列表的狀態色相同(系統色，深淺色與高對比由系統處理);狀態一律同時有文字。
    var color: AnyShapeStyle {
        switch self {
        case .offline: AnyShapeStyle(.gray)
        case .working: AnyShapeStyle(.orange)
        case .needsYou: AnyShapeStyle(.tint)
        case .done: AnyShapeStyle(.teal)
        case .online: AnyShapeStyle(.green)
        }
    }
}

/// 對話底部的工作中指示(F5.11):即時預覽(次要色)+ 3×3 點陣 +「Working…」／「Writing…」+ 經過時間。
/// 內容層，不用玻璃。Reduce Motion 時點陣不動。
struct WorkingIndicatorView: View {
    let since: Date
    let preview: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let preview {
                Text(preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondaryText)
                    // AX 字級不限行數(DESIGN.md:支援到 AX5 不截斷,#35)。
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("conversation.livePreview")
            }
            HStack(spacing: 8) {
                WorkingDotsView(reduceMotion: reduceMotion)
                Text(preview == nil ? "Working…" : "Writing…")
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text(WorkingElapsed.text(seconds: Int(context.date.timeIntervalSince(since))))
                        .monospacedDigit()
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondaryText)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("conversation.working")
    }
}

struct WorkingDotsView: View {
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.18)) { context in
            let frame = Int(context.date.timeIntervalSinceReferenceDate / 0.18)
            let opacities = WorkingDots.opacities(frame: frame, reduceMotion: reduceMotion)
            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                ForEach(0..<3, id: \.self) { row in
                    GridRow {
                        ForEach(0..<3, id: \.self) { column in
                            Circle()
                                .frame(width: 3.5, height: 3.5)
                                .opacity(opacities[row * 3 + column])
                        }
                    }
                }
            }
        }
        .foregroundStyle(.orange)
        .accessibilityHidden(true)
    }
}
