import Foundation
import PurrdrCore
import Testing

/// 順暢度除錯層讀的快照(#484):離底距離、可見列數與黑框判斷。
@Suite("順暢度快照")
struct ScrollSmoothnessSnapshotTests {
    @Test("離底距離:內容高減可見高減位移")
    func distanceFromBottom() {
        let snapshot = ScrollSmoothnessSnapshot(contentHeight: 1000, containerHeight: 600, contentOffsetY: 300, topInset: 0, visibleRowCount: 4)
        #expect(snapshot.distanceFromBottom == 100)
    }

    @Test("頂部 inset 要從離底距離扣掉")
    func topInsetIsSubtracted() {
        let snapshot = ScrollSmoothnessSnapshot(contentHeight: 1000, containerHeight: 600, contentOffsetY: 300, topInset: 50, visibleRowCount: 4)
        #expect(snapshot.distanceFromBottom == 50)
    }

    @Test("可見範圍超出內容底緣、或內容比畫面高卻沒有可見列，標為疑似黑框")
    func suspectedBlankDetection() {
        let beyond = ScrollSmoothnessSnapshot(contentHeight: 1000, containerHeight: 600, contentOffsetY: 500, topInset: 0, visibleRowCount: 2)
        let noRows = ScrollSmoothnessSnapshot(contentHeight: 1000, containerHeight: 600, contentOffsetY: 100, topInset: 0, visibleRowCount: 0)
        let healthy = ScrollSmoothnessSnapshot(contentHeight: 1000, containerHeight: 600, contentOffsetY: 400, topInset: 0, visibleRowCount: 3)
        #expect(beyond.isSuspectedBlank)
        #expect(noRows.isSuspectedBlank)
        #expect(healthy.isSuspectedBlank == false)
    }

    @Test("內容比畫面矮時不算疑似黑框")
    func shortContentIsNotBlank() {
        let snapshot = ScrollSmoothnessSnapshot(contentHeight: 200, containerHeight: 600, contentOffsetY: 0, topInset: 0, visibleRowCount: 0)
        #expect(snapshot.isSuspectedBlank == false)
    }

    @Test("文字一行:離底距離四捨五入、可見列數、黑框標記")
    func overlayText() {
        let healthy = ScrollSmoothnessSnapshot(contentHeight: 1000, containerHeight: 600, contentOffsetY: 399.6, topInset: 0, visibleRowCount: 3)
        #expect(healthy.overlayText == "離底 0 pt ・ 可見 3 列")
        let blank = ScrollSmoothnessSnapshot(contentHeight: 1000, containerHeight: 600, contentOffsetY: 500, topInset: 0, visibleRowCount: 2)
        #expect(blank.overlayText == "離底 -100 pt ・ 可見 2 列 ・ 疑似黑框")
    }

    @Test("紀錄保留最新快照，並累計樣本與黑框次數")
    func logKeepsLatestAndCountsBlanks() {
        var log = ScrollSmoothnessLog()
        log.record(ScrollSmoothnessSnapshot(contentHeight: 1000, containerHeight: 600, contentOffsetY: 500, topInset: 0, visibleRowCount: 2))
        log.record(ScrollSmoothnessSnapshot(contentHeight: 1000, containerHeight: 600, contentOffsetY: 400, topInset: 0, visibleRowCount: 3))
        #expect(log.latest?.visibleRowCount == 3)
        #expect(log.suspectedBlankCount == 1)
        #expect(log.sampleCount == 2)
    }
}
