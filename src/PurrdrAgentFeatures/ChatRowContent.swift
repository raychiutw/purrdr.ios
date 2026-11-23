import Foundation
import PurrdrCore

/// 聊天列(#502,設計稿 A 寬鬆版)的內容:純值,不含版面。列 view(`ChatRowView`)只負責把它畫出來。
///
/// 每列統一的兩行主資訊加預覽(#505):第一行 Tab 名稱(沒有名稱時是「Tab N」),
/// 第二行 session 標題(與第一行相同或沒有就省略;「離開期間」小標籤放這一行開頭),第三行預覽;右欄是時間與用量環。
public struct ChatRowContent: Equatable, Sendable {
    public enum Line: Equatable, Sendable {
        /// 第一行:Tab 名稱(17pt Semibold);沒有 Tab 的 pane 是它的內容標題。
        case title(String)
        /// 第二行:開頭是「離開期間」小標籤(有才有),後面是 session 標題(次要色)。
        case detail(awayBadge: String?, sessionTitle: String?)
        /// 第三行:預覽(次要色)。
        case preview(String)
    }

    public enum Avatar: Equatable, Sendable {
        case agent(kind: String)
        case terminal
    }

    public var avatar: Avatar
    /// 頭像右下角的狀態圓點;只有終端機的 Tab 沒有。
    public var statusDot: AvatarStatusDot?
    public var lines: [Line]
    public var time: AgentRow.Time?
    /// 用量環的 context 百分比。
    public var contextPercent: Int?

    public init(tab: SpacesTab) {
        switch tab.avatar {
        case .agent(let kind, let status):
            avatar = .agent(kind: kind)
            statusDot = status.statusDot
        case .terminal:
            avatar = .terminal
            statusDot = nil
        }
        let first = tab.tabName ?? tab.contentTitle
        let second = first == tab.contentTitle ? nil : tab.contentTitle
        var lines: [Line] = [.title(first)]
        let badge = tab.agent.flatMap { $0.isAway ? Self.awayBadgeText(turns: $0.awayTurns) : nil }
        if badge != nil || second != nil {
            lines.append(.detail(awayBadge: badge, sessionTitle: second))
        }
        if let agent = tab.agent, let text = Self.previewText(agent.preview) {
            lines.append(.preview(text))
        }
        self.lines = lines
        time = tab.agent?.time
        contextPercent = tab.agent?.progress?.contextPercent
    }

    /// 預覽文字:需要你時是「Waiting for your input」,使用者自己送出的加「You: 」;沒有訊息時 `nil`(不畫這一行)。
    public static func previewText(_ preview: AgentRow.Preview) -> String? {
        switch preview {
        case .needsInput: String(localized: "Waiting for your input")
        case .message(let text, let fromYou): fromYou ? String(localized: "You: \(text)") : text
        case .none: nil
        }
    }

    /// 「While away」,算出輪數後是「While away · +N turns」(#308)。
    public static func awayBadgeText(turns: Int?) -> String {
        guard let turns, turns > 0 else { return String(localized: "While away") }
        let turnsText = String(localized: "\(turns) turns")
        return String(localized: "While away · +\(turnsText)")
    }

    /// 每行的行數上限:一般字級一行(列高對齊設計稿的 101pt);輔助使用字級不限制(DESIGN.md:支援到 AX5 不截斷)。
    public static func lineLimit(accessibilitySize: Bool) -> Int? {
        accessibilitySize ? nil : 1
    }
}
