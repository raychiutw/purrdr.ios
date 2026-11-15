import Foundation

/// 主機指令建構：產生在主機上執行 herdr 的指令字串。
///
/// 目前只有 POSIX `sh`(macOS、Linux);Windows 的 `-EncodedCommand` 包裝(ADR-0002)在 Windows 主機那張票加入。
public enum HerdrCommand {
    /// 非互動 SSH shell 不讀 profile,herdr 的安裝位置常不在 PATH(行為規格 §3.2)。
    static let pathPrefix =
        #"PATH="$HOME/.local/bin:$HOME/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH""#

    /// 執行 `herdr remote-api-bridge`:stdin 一行請求進、stdout 一行回應出(行為規格 §3.3)。
    public static func bridge(_ herdr: HerdrInstallation = HerdrInstallation()) -> String {
        herdrCommand(herdr, "remote-api-bridge")
    }

    /// 已安裝的 herdr 執行檔版本(`herdr 0.9.5`)。可能與執行中的伺服器版本不同(行為規格 §3.1)。
    /// 執行檔層級的指令，不帶 `--session`。
    public static func version(_ herdr: HerdrInstallation) -> String {
        "\(pathPrefix) \(quotedPath(herdr.path)) --version"
    }

    /// 更新 herdr,並嘗試讓執行中的伺服器交接到新版(行為規格 F15)。
    ///
    /// 不帶 `--session`:更新換的是執行檔，所有 session 共用。
    public static func update(_ herdr: HerdrInstallation) -> String {
        "\(pathPrefix) \(quotedPath(herdr.path)) update --handoff"
    }

    /// 主機作業系統(POSIX)。`Darwin`、`Linux`…
    public static let operatingSystem = "\(pathPrefix) uname -s"

    /// 具名 session 依 herdr 的 `--session` 規則放在子指令之前(#37)。
    private static func herdrCommand(_ herdr: HerdrInstallation, _ arguments: String) -> String {
        let session = herdr.session.map { " --session \(PosixShell.quote($0))" } ?? ""
        return "\(pathPrefix) \(quotedPath(herdr.path))\(session) \(arguments)"
    }

    /// 以 controller 身分接上 Pane 的終端機(`herdr terminal session control`,ADR-0005):
    /// stdout 是 NDJSON 畫面更新，stdin 是 NDJSON 輸入，不需要 PTY。
    ///
    /// `takeover` 只在使用者按「接管」時才帶——首次開啟與重新連線都不自動搶(行為規格 §6.3)。
    public static func terminalSessionControl(
        target: String, columns: Int, rows: Int, takeover: Bool = false, herdr: HerdrInstallation = HerdrInstallation()
    ) -> String {
        herdrCommand(herdr, "terminal session control \(PosixShell.quote(target))")
            + " --cols \(columns) --rows \(rows)" + (takeover ? " --takeover" : "")
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

/// 主機上的 herdr:執行檔路徑與具名 session(#37 故事 23)。
public struct HerdrInstallation: Sendable, Hashable, Codable {
    public var path: String
    public var session: String?

    /// 路徑空白視為 `herdr`;session 空白或 `default` 視為預設 session(行為規格 F1.2)。
    public init(path: String = "herdr", session: String? = nil) {
        let path = path.trimmingCharacters(in: .whitespaces)
        let session = session?.trimmingCharacters(in: .whitespaces)
        self.path = path.isEmpty ? "herdr" : path
        self.session = session.flatMap { $0.isEmpty || $0 == "default" ? nil : $0 }
    }

    public var isDefault: Bool { path == "herdr" && session == nil }
}
