import Foundation

/// 聊天列表某一刻的量測(順暢度除錯層讀它,#484)。新舊列表都只要把量到的值交給 `ScrollSmoothnessReporting`。
public struct ScrollSmoothnessSnapshot: Equatable, Sendable {
    /// 距尾端超過這個距離(內容比畫面高時)視為可見範圍停在內容之外。
    public static let blankThreshold = 48.0

    public var contentHeight: Double
    public var containerHeight: Double
    public var contentOffsetY: Double
    public var topInset: Double
    public var visibleRowCount: Int

    public init(contentHeight: Double, containerHeight: Double, contentOffsetY: Double, topInset: Double, visibleRowCount: Int) {
        self.contentHeight = contentHeight
        self.containerHeight = containerHeight
        self.contentOffsetY = contentOffsetY
        self.topInset = topInset
        self.visibleRowCount = visibleRowCount
    }

    /// 可見範圍底緣到內容底緣的距離;停在內容之外時是負的。
    public var distanceFromBottom: Double { contentHeight - containerHeight - topInset - contentOffsetY }

    /// 內容比畫面高，卻停在內容之外或一列都沒顯示:實機上看到的黑框。
    public var isSuspectedBlank: Bool {
        contentHeight > containerHeight && (distanceFromBottom < -Self.blankThreshold || visibleRowCount == 0)
    }

    /// 疊在畫面上的一行文字。
    public var overlayText: String {
        let base = "離底 \(Int(distanceFromBottom.rounded())) pt ・ 可見 \(visibleRowCount) 列"
        return isSuspectedBlank ? base + " ・ 疑似黑框" : base
    }
}

/// 列表把量測交給除錯層的介面(#484);新列表(#480)實作捲動回呼時呼叫 `report`，除錯層不必改。
@MainActor
public protocol ScrollSmoothnessReporting: AnyObject {
    func report(_ snapshot: ScrollSmoothnessSnapshot)
}

/// 量測紀錄:保留最新快照、樣本數與疑似黑框次數。
public struct ScrollSmoothnessLog: Equatable, Sendable {
    public private(set) var latest: ScrollSmoothnessSnapshot?
    public private(set) var sampleCount = 0
    public private(set) var suspectedBlankCount = 0

    public init() {}

    public mutating func record(_ snapshot: ScrollSmoothnessSnapshot) {
        latest = snapshot
        sampleCount += 1
        if snapshot.isSuspectedBlank { suspectedBlankCount += 1 }
    }
}
