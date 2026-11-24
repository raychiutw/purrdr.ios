import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 聊天列頭像加右下角狀態圓點(#316、#502)。
///
/// 狀態是四色圓點(`AvatarStatusDot`;實心＝未讀、空心＝已讀),12pt、疊在頭像右下角外緣,外圈 2pt 墊列背景色。
/// 顏色之外沒有文字或符號旁證,所以形狀差異只靠實心／空心;狀態由列的 VoiceOver 句子念,這裡不另成元素。
struct AgentStatusAvatar: View {
    enum Content {
        case agent(AgentKind)
        case terminal
    }

    let content: Content
    /// 沒有值時不畫狀態(只有終端機的 Tab)。
    let dot: AvatarStatusDot?

    /// 頭像方塊最大放大到的字級(使用者決定:大字級時不要放得太大;文字列照常隨字級放大)。
    /// 只夾方塊與狀態圓點的大小;方塊裡的字母與符號仍用實際字級,才不會被稽核判為 Dynamic Type 不支援。
    static let largestTypeSize = DynamicTypeSize.accessibility1

    /// 狀態圓點超出頭像右、下外緣的距離(設計稿標註 3pt)。
    static let dotOverhang: CGFloat = 3

    /// 載入骨架(`redacted(.placeholder)`)時頭像畫成灰塊、不畫狀態(#496)。
    @Environment(\.redactionReasons) private var redactionReasons

    var body: some View {
        avatar
            .overlay(alignment: .bottomTrailing) {
                if let dot, !redactionReasons.contains(.placeholder) {
                    AvatarStatusDotView(dot: dot)
                        .dynamicTypeSize(...Self.largestTypeSize)
                        .offset(x: Self.dotOverhang, y: Self.dotOverhang)
                }
            }
            // 圓點超出頭像外緣,列的排版要把它算進去。
            .padding(.trailing, Self.dotOverhang)
            .padding(.bottom, Self.dotOverhang)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var avatar: some View {
        if redactionReasons.contains(.placeholder) {
            SkeletonBlock(width: AvatarBox.Size.row.base, height: AvatarBox.Size.row.base, cornerRadius: AvatarBox.Size.row.radius)
        } else {
            realAvatar
        }
    }

    @ViewBuilder
    private var realAvatar: some View {
        switch content {
        case .agent(let kind):
            AgentKindAvatar(kind: kind, size: .row)
        case .terminal:
            TerminalAvatar()
        }
    }
}

/// 狀態圓點:12pt,外圈 2pt 列背景色。實心＝色塊;空心＝2pt 色環、中間透出列底色。
struct AvatarStatusDotView: View {
    let dot: AvatarStatusDot
    @ScaledMetric(relativeTo: .subheadline) private var diameter: CGFloat = 12

    var body: some View {
        ZStack {
            if dot.isFilled {
                Circle().fill(dot.tone.style)
            } else {
                Circle().fill(.listRowSurface)
                Circle().strokeBorder(dot.tone.style, lineWidth: 2)
            }
        }
        .frame(width: diameter, height: diameter)
        .padding(2)
        .background(.listRowSurface, in: Circle())
        .dimsWhenWindowInactive()
    }
}

/// 只有終端機的 Tab:中性底色的終端機符號，大小與 Agent 種類頭像相同。
private struct TerminalAvatar: View {
    @ScaledMetric(relativeTo: .subheadline) private var symbolSize: CGFloat = 20

    var body: some View {
        AvatarBox(fill: AgentKindAvatarStyle(kind: .unknown("")).palette.color, size: .row)
            .dynamicTypeSize(...AgentStatusAvatar.largestTypeSize)
            .overlay {
                Image(systemName: "terminal")
                    .font(.system(size: symbolSize, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}

/// 頭像的圓角方塊:大小隨字級放大,呼叫端在外面夾上限(方塊裡的字母與符號不在夾住的範圍內)。
struct AvatarBox: View {
    enum Size {
        /// 對話標題列旁的小頭像(20pt)。
        case compact
        /// 一般(36pt)。
        case regular
        /// 聊天列(#502,設計稿 A 寬鬆版:48pt、圓角 14)。
        case row

        var base: CGFloat {
            switch self {
            case .compact: 20
            case .regular: 36
            case .row: 48
            }
        }

        var radius: CGFloat {
            switch self {
            case .compact: 6
            case .regular: 10
            case .row: 14
            }
        }

        var textStyle: Font.TextStyle { self == .compact ? .caption : .subheadline }
    }

    let fill: Color
    private let size: Size
    @ScaledMetric private var side: CGFloat

    init(fill: Color, size: Size = .regular) {
        self.fill = fill
        self.size = size
        _side = ScaledMetric(wrappedValue: size.base, relativeTo: size.textStyle)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size.radius).fill(fill).frame(width: side, height: side)
    }
}

extension ShapeStyle where Self == Color {
    /// `insetGrouped` 列表的列底色(狀態符號的圓底，跟列背景融在一起)。
    static var listRowSurface: Color {
        #if canImport(UIKit)
        AppSurface.groupedRow
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }
}
