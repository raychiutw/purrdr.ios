import CoreGraphics
import PurrdrFeatures
import Testing

/// 終端機按鍵列在 iPhone Duo 折疊區(ReservedRegion `.division`)的切分(#69)。
@Suite("終端機按鍵列避開折疊區")
struct TerminalKeyBarFoldTests {
    @Test("沒有作用中的折疊區時不切分")
    func noDivisionKeepsSingleBar() {
        #expect(TerminalKeyBarFoldSplit(barWidth: 800, divisionFrames: []) == nil)
    }

    @Test("書本姿態的直向折疊穿過按鍵列：折疊前是按鍵、折疊區留空")
    func verticalFoldSplitsBarAroundDivision() throws {
        let fold = CGRect(x: 380, y: -100, width: 40, height: 300)

        let split = try #require(TerminalKeyBarFoldSplit(barWidth: 800, divisionFrames: [fold]))

        #expect(split.leadingWidth == 380)
        #expect(split.gapWidth == 40)
    }

    @Test("筆電姿態的橫向折疊不切分按鍵列")
    func horizontalFoldKeepsSingleBar() {
        let fold = CGRect(x: -10, y: 20, width: 820, height: 40)

        #expect(TerminalKeyBarFoldSplit(barWidth: 800, divisionFrames: [fold]) == nil)
    }

    @Test("折疊區在按鍵列範圍外時不切分")
    func divisionOutsideBarKeepsSingleBar() {
        let fold = CGRect(x: 820, y: -100, width: 40, height: 300)

        #expect(TerminalKeyBarFoldSplit(barWidth: 800, divisionFrames: [fold]) == nil)
    }

    @Test("折疊區太靠邊、任一側放不下兩顆 44pt 按鍵時不切分")
    func divisionTooCloseToEdgeKeepsSingleBar() {
        let nearLeading = CGRect(x: 60, y: -100, width: 40, height: 300)
        let nearTrailing = CGRect(x: 700, y: -100, width: 40, height: 300)

        #expect(TerminalKeyBarFoldSplit(barWidth: 800, divisionFrames: [nearLeading]) == nil)
        #expect(TerminalKeyBarFoldSplit(barWidth: 800, divisionFrames: [nearTrailing]) == nil)
    }
}
