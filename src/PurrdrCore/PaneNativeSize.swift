import Foundation

/// Pane 在電腦上的終端機格數(PTY 的欄列數)。
public struct PaneNativeSize: Sendable, Equatable {
    public var columns: Int
    public var rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }
}

extension HostSnapshot {
    /// herdr 沒開電腦 client(headless)時 layout 的預設尺寸;與 PTY 的實際尺寸無關(`config.rs` 的 `DEFAULT_HEADLESS_COLS/ROWS`)。
    static let headlessLayoutSize = (width: 120, height: 40)

    /// `paneID` 在電腦上目前的格數,保留電腦版面(#357)時 handshake 用它;herdr 0.9.5 接上 controller 一定把 Pane 改成
    /// handshake 的尺寸,所以帶原尺寸才不會動到電腦上的版面。
    ///
    /// - 列數:`scroll.viewport_rows`,精確。
    /// - 欄數:herdr 沒有 API,由 layout 的 `rect.width` 推算:多 Pane(沒放大)扣左右邊框各 1 欄,再扣 scrollbar 1 欄
    ///   (不在 alternate screen 且寬度 > 4)。主機改過 `pane_borders`／`pane_gaps` 等設定時可能差 1–2 欄。
    /// - 電腦沒開 herdr(layout 是 headless 的 120×40)或資料不全時回 `nil`,呼叫端退回手機尺寸。
    ///
    /// 數字來自 herdr 0.9.5 真主機實測,見 `docs/research/terminal-session-control-macos.md`。
    public func nativeSize(ofPane paneID: String, isAlternateScreen: Bool = false) -> PaneNativeSize? {
        guard let rows = panes.first(where: { $0.id == paneID })?.viewportRows, rows > 0,
              let layout = layouts?.first(where: { $0.panes.contains { $0.paneID == paneID } }),
              let rect = layout.panes.first(where: { $0.paneID == paneID })?.rect, rect.width > 0 else { return nil }
        let right = layout.panes.map { $0.rect.x + $0.rect.width }.max() ?? 0
        let bottom = layout.panes.map { $0.rect.y + $0.rect.height }.max() ?? 0
        guard (right, bottom) != Self.headlessLayoutSize else { return nil }
        var columns = rect.width
        if layout.panes.count > 1, !layout.zoomed { columns -= 2 }
        if !isAlternateScreen, rect.width > 4 { columns -= 1 }
        guard columns > 0 else { return nil }
        return PaneNativeSize(columns: columns, rows: rows)
    }
}
