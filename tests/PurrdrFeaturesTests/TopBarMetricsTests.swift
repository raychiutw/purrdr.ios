import Testing

@testable import PurrdrFeatures

/// 頂端工具列尺寸(#475):所有 tab 的按鈕、膠囊與帳號頭像共用同一組常數,聊天標題膠囊也是單行 44pt。
@Suite("頂端工具列尺寸")
struct TopBarMetricsTests {
    @Test("按鈕與膠囊 44pt、圓鈕直徑與高度相同")
    func values() {
        #expect(TopBarMetrics.controlHeight == 44)
        #expect(TopBarMetrics.circleDiameter == 44)
        #expect(TopBarMetrics.circleDiameter == TopBarMetrics.controlHeight)
        #expect(TopBarMetrics.avatarDiameter == 30)
        #expect(TopBarMetrics.avatarDiameter < TopBarMetrics.circleDiameter)
        #expect(TopBarMetrics.titleCapsuleHeight == TopBarMetrics.controlHeight)
    }
}
