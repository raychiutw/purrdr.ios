import SwiftUI

/// 還沒送進對話的訊息共用的泡泡外觀(spec #336):虛線、半透明的使用者泡泡。
/// 撤回倒數(#300)、離線佇列(#301)、做完再送(#305)都用它,只差標籤與動作;出問題時邊框變紅。
struct PendingBubbleBody: View {
    let text: String
    /// 做完再送的送出順序(1 起算);其他沒有編號。
    var number: Int?
    var isProblem = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let number {
                Text(verbatim: "\(number)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondaryText)
            }
            Text(text)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(
                    isProblem ? AnyShapeStyle(.red) : AnyShapeStyle(.secondaryText),
                    style: StrokeStyle(lineWidth: isProblem ? 1.5 : 1, dash: [4, 3]))
        }
        .opacity(isProblem ? 1 : 0.75)
    }
}

/// 一則待送訊息的一列:靠右的虛線泡泡加下方的標籤與動作(`footer`)。
struct PendingBubbleRow<Footer: View>: View {
    let text: String
    var isProblem = false
    let bubbleLabel: Text
    @ViewBuilder let footer: Footer

    var body: some View {
        HStack {
            Spacer(minLength: 44)
            VStack(alignment: .trailing, spacing: 2) {
                PendingBubbleBody(text: text, isProblem: isProblem)
                    .accessibilityLabel(bubbleLabel)
                footer
                    .font(.caption)
            }
        }
    }
}
