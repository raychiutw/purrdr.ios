import Testing

@testable import PurrdrFeatures

/// 可點列表列、卡片與縮圖的灰色按壓回饋(#234)。
@Suite("按壓回饋")
struct PressFeedbackTests {
    @Test("沒按下時不畫按壓層", arguments: [PressFeedback.row, .card, .thumbnail])
    func noHighlightWhenNotPressed(feedback: PressFeedback) {
        #expect(feedback.highlight(isPressed: false) == nil)
    }

    @Test("列表列按下時在內容底下畫中性灰")
    func rowDrawsNeutralFillBehindContent() {
        #expect(PressFeedback.row.highlight(isPressed: true) == .neutralFillBehind)
    }

    @Test("卡片自己有底色，按下時把中性灰疊在上面")
    func cardDrawsNeutralFillOverContent() {
        #expect(PressFeedback.card.highlight(isPressed: true) == .neutralFillOver)
    }

    @Test("縮圖按下時疊 15% 黑")
    func thumbnailDimsWithBlackOverlay() {
        #expect(PressFeedback.thumbnail.highlight(isPressed: true) == .dimmed(opacity: 0.15))
    }
}
