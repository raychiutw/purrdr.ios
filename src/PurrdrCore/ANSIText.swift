import Foundation

/// 含 ANSI 跳脫序列的終端機文字(`pane.read` 的 `.ansi` 格式、對話紀錄裡的本地指令輸出)。
public enum ANSIText {
    /// 去掉 ANSI 跳脫序列:OSC(含 OSC 8 超連結，以 BEL 或 ST 結尾)、CSI(含 `<=>?` 私有參數、`:` 子參數與中間位元組)、
    /// 其他跳脫(`ESC 7`、`ESC (B` 之類)。不動 `\r` 與換行。正規式裡一定要真的含 ESC 字元(R-Q10)。
    public static func strip(_ text: String) -> String {
        // 沒有 ESC 就沒有跳脫序列可去(即時預覽每行都呼叫,#585)。
        guard text.utf8.contains(0x1B) else { return text }
        return text.replacingMatches(osc, with: "")
            .replacingMatches(csi, with: "")
            .replacingMatches(other, with: "")
    }

    // 正規式只建一次(#585)。pattern 是寫死的字面值,建不起來是程式錯誤。
    private static let osc = makeRegex("\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)")
    private static let csi = makeRegex("\u{1B}\\[[0-?]*[ -/]*[@-~]")
    private static let other = makeRegex("\u{1B}[ -/]*[0-Z\\\\-~]")

    private static func makeRegex(_ pattern: String) -> NSRegularExpression {
        do { return try NSRegularExpression(pattern: pattern) } catch { preconditionFailure("ANSI pattern: \(error)") }
    }
}
