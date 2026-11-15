/// 主機指令建構：產生在主機上執行 herdr 的指令字串。
///
/// 目前只有 POSIX `sh`(macOS、Linux);Windows 的 `-EncodedCommand` 包裝(ADR-0002)在 Windows 主機那張票加入。
public enum HerdrCommand {
    /// 非互動 SSH shell 不讀 profile,herdr 的安裝位置常不在 PATH(行為規格 §3.2)。
    static let pathPrefix =
        #"PATH="$HOME/.local/bin:$HOME/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH""#

    /// 執行 `herdr remote-api-bridge`:stdin 一行請求進、stdout 一行回應出(行為規格 §3.3)。
    public static func bridge(herdrPath: String = "herdr") -> String {
        "\(pathPrefix) \(quotedPath(herdrPath)) remote-api-bridge"
    }

    /// herdr 路徑以 `~/` 開頭時，只把 `~/` 換成 `"$HOME"/`,其餘照樣引號(引號內的 `~` 不展開)。
    static func quotedPath(_ path: String) -> String {
        if path.hasPrefix("~/") {
            return #""$HOME"/"# + PosixShell.quote(String(path.dropFirst(2)))
        }
        return PosixShell.quote(path)
    }
}

/// POSIX shell 的引號規則。
public enum PosixShell {
    /// 整段用單引號包住，內部單引號寫成 `'"'"'`。不用反斜線：fish 在單引號內仍把 `\` 當特殊字元,
    /// 而 sshd 會先把指令交給使用者的登入 shell(行為規格 §3.2)。
    public static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'"'"'"#) + "'"
    }
}
