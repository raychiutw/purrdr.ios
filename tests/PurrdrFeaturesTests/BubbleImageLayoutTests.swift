import CoreGraphics
@testable import PurrdrFeatures
import Testing

/// 使用者泡泡的圖片排版(#465,設計稿第 30 組):單張依原圖比例、多張排成 124pt 方塊格子。
@Suite("泡泡圖片排版")
struct BubbleImageLayoutTests {
    @Test("單張:依原圖比例,長邊 220pt")
    func singleImageKeepsAspectRatio() {
        let layout = BubbleImageLayout(count: 1)

        #expect(layout.isGrid == false)
        #expect(layout.size(forImage: CGSize(width: 400, height: 200)) == CGSize(width: 220, height: 110))
        #expect(layout.size(forImage: CGSize(width: 100, height: 300)) == CGSize(width: 73, height: 220))
        #expect(layout.size(forImage: .zero) == CGSize(width: 220, height: 220))
    }

    @Test("多張:每張都是 124pt 方塊,不論原圖比例;兩欄、間距 4pt")
    func multipleImagesFormSquareGrid() {
        for count in 2...6 {
            let layout = BubbleImageLayout(count: count)
            #expect(layout.isGrid)
            #expect(layout.size(forImage: CGSize(width: 400, height: 200)) == CGSize(width: 124, height: 124))
            #expect(layout.size(forImage: .zero) == CGSize(width: 124, height: 124))
        }
        #expect(BubbleImageLayout.gridColumns == 2)
        #expect(BubbleImageLayout.gridSpacing == 4)
    }

    @Test("沒有圖時不是格子")
    func emptyIsNotGrid() {
        #expect(BubbleImageLayout(count: 0).isGrid == false)
    }
}
