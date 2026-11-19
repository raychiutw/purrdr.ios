/// 可點列表列、卡片與縮圖按下時的外觀(#234,DESIGN.md「按壓回饋」)。
enum PressFeedback: Sendable, CaseIterable {
    /// 本身沒有底色的列(slash 選單、建議提示詞、側欄主機列、大標題選單)。
    case row
    /// 自己有不透明底的卡片(方案卡片、Google 鈕)。
    case card
    /// 圖片縮圖。
    case thumbnail

    /// 按下時要畫的一層;沒按下時是 `nil`。
    func highlight(isPressed: Bool) -> PressHighlight? {
        guard isPressed else { return nil }
        switch self {
        case .row: return .neutralFillBehind
        case .card: return .neutralFillOver
        case .thumbnail: return .dimmed(opacity: 0.15)
        }
    }
}

/// 按壓態畫的那一層;一律是中性灰，不用主色。
enum PressHighlight: Equatable, Sendable {
    /// 系統第三層填色(`.fill.tertiary`)畫在內容底下。
    case neutralFillBehind
    /// 系統第三層填色疊在內容上面(卡片自己的底色會蓋住畫在底下的那層)。
    case neutralFillOver
    /// 黑色半透明疊在圖片上。
    case dimmed(opacity: Double)
}
