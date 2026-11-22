import Foundation
import Testing

@testable import PurrdrFeatures

@Suite("圖片檢視器的清單與換頁")
struct ImageViewerPagingTests {
    @Test("起始索引超出範圍時夾回清單內")
    func startIndexIsClamped() {
        #expect(ImageViewerPaging(count: 3, startIndex: 1).index == 1)
        #expect(ImageViewerPaging(count: 3, startIndex: 9).index == 2)
        #expect(ImageViewerPaging(count: 3, startIndex: -4).index == 0)
        #expect(ImageViewerPaging(count: 0, startIndex: 2).index == 0)
    }

    @Test("頁數文字:一張圖不顯示，多張顯示「目前 / 總數」")
    func pageLabel() {
        #expect(ImageViewerPaging(count: 1, startIndex: 0).pageLabel == nil)
        #expect(ImageViewerPaging(count: 2, startIndex: 0).pageLabel == "1 / 2")
        #expect(ImageViewerPaging(count: 3, startIndex: 2).pageLabel == "3 / 3")
    }

    @Test("往右到最後一張停住，往左到第一張停住")
    func boundaries() {
        var paging = ImageViewerPaging(count: 2, startIndex: 0)
        #expect(paging.canGoPrevious == false)
        #expect(paging.canGoNext)
        paging.goPrevious()
        #expect(paging.index == 0)
        paging.goNext()
        #expect(paging.index == 1)
        #expect(paging.canGoNext == false)
        paging.goNext()
        #expect(paging.index == 1)
        paging.goPrevious()
        #expect(paging.index == 0)
    }

    @Test("select 夾在範圍內")
    func select() {
        var paging = ImageViewerPaging(count: 3, startIndex: 0)
        paging.select(2)
        #expect(paging.index == 2)
        paging.select(7)
        #expect(paging.index == 2)
        paging.select(-1)
        #expect(paging.index == 0)
    }
}

@Suite("圖片檢視器的清單來源")
struct ImageViewerPlanTests {
    let a = URL(filePath: "/tmp/a.png")
    let c = URL(filePath: "/tmp/c.png")

    @Test("同一則訊息的圖片依序入清單，起始索引指向點的那張")
    func entriesFollowTheMessageOrder() throws {
        let plan = try #require(ImageViewerPlan(
            images: [a, nil, c], hostPaths: [nil, "/up/b.png", nil], tapped: 1, isViewable: { _ in true }))
        #expect(plan.entries == [.local(a), .host("/up/b.png"), .local(c)])
        #expect(plan.startIndex == 1)
    }

    @Test("主機上找不到的圖不進清單，起始索引跟著位移")
    func unviewableEntriesAreSkipped() throws {
        let plan = try #require(ImageViewerPlan(
            images: [nil, nil, c], hostPaths: ["/up/gone.png", "/up/b.png", nil], tapped: 2,
            isViewable: { $0 != "/up/gone.png" }))
        #expect(plan.entries == [.host("/up/b.png"), .local(c)])
        #expect(plan.startIndex == 1)
    }

    @Test("沒有任何可看的圖回 nil")
    func nothingToShow() {
        #expect(ImageViewerPlan(images: [nil], hostPaths: ["/up/x.png"], tapped: 0, isViewable: { _ in false }) == nil)
    }
}
