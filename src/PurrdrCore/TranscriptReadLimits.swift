import Foundation

/// 點進聊天時從主機讀對話紀錄的量(#656 grill 結論):開啟讀的行數、開啟與每一頁的原始 bytes 上限、
/// 「視窗內沒有可讀訊息」時自動往前補讀的頁數。數值只在這裡,SSH、HTTPS 與 Windows 三條路都吃同一組。
///
/// bytes 上限依網路類型(`TrafficNetwork`,與流量計量同一個來源)而定;圖片 base64 在主機上先剝掉,上限是剝掉之後的量。
/// 最壞情況(行動網路):開啟一次聊天往返 2 次(開啟加 1 頁補讀),各最多 256 KiB。
public struct TranscriptReadLimits: Sendable, Equatable {
    /// 開啟時讀最後幾行。
    public var openLines: Int
    /// 開啟、補讀與往上翻每一頁的原始 bytes 上限(只含完整的行)。
    public var maxBytes: Int
    /// 開啟視窗完全沒有可讀訊息時,自動往前補讀最多幾頁。
    public var emptyWindowBackfillPages: Int

    public init(openLines: Int, maxBytes: Int, emptyWindowBackfillPages: Int) {
        self.openLines = openLines
        self.maxBytes = maxBytes
        self.emptyWindowBackfillPages = emptyWindowBackfillPages
    }

    /// 目前網路的限額;`nil`(還不知道)與 Wi-Fi 以外的網路用保守值。
    public static func limits(for network: TrafficNetwork?) -> TranscriptReadLimits {
        TranscriptReadLimits(
            openLines: TranscriptReader.openingLines, maxBytes: network == .wifi ? 512 << 10 : 256 << 10, emptyWindowBackfillPages: 1)
    }

    /// 不知道網路時用的保守值。
    public static let conservative = limits(for: nil)
}
