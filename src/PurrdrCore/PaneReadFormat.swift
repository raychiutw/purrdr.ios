/// `pane.read` 回傳的畫面格式。
public enum PaneReadFormat: Sendable, Equatable {
    /// 純文字(herdr 去掉跳脫序列)。
    case text
    /// 保留 ANSI 跳脫序列(SGR 顏色、dim 等)。
    case ansi
}
