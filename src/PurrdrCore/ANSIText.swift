import Foundation

/// 含 ANSI 跳脫序列的終端機文字(`pane.read` 的 `.ansi` 格式、對話紀錄裡的本地指令輸出)。
public enum ANSIText {
    /// 去掉 ANSI 跳脫序列:OSC(含 OSC 8 超連結，以 BEL 或 ST 結尾)、CSI(含 `<=>?` 私有參數、`:` 子參數與中間位元組)、
    /// 其他跳脫(`ESC 7`、`ESC (B` 之類)。不動 `\r` 與換行。正規式裡一定要真的含 ESC 字元(R-Q10)。
    public static func strip(_ text: String) -> String {
        text.replacingMatches("\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)", with: "")
            .replacingMatches("\u{1B}\\[[0-?]*[ -/]*[@-~]", with: "")
            .replacingMatches("\u{1B}[ -/]*[0-Z\\\\-~]", with: "")
    }
}
