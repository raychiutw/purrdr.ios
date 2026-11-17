import Foundation

/// Windows 主機的指令外殼(行為規格 §3.9、§11.2「指令外殼」)。
///
/// 每個指令都包成 `powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand <腳本的 UTF-16LE base64>`:
/// OpenSSH 的預設 shell 是 cmd、PowerShell 或 Git Bash 都能執行同一行(base64 只有 `A-Za-z0-9+/=`,
/// 三種 shell 都不會改動),所以**不要求 Git Bash**。也避開 OpenSSH for Windows 以雙引號包裝指令時
/// 展開 `$` 與反引號的問題。
public enum PowerShell {
    static let launcher = "powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand "

    /// 偵測原生 Windows(行為規格 §3.9):預設 shell 是 cmd 或 PowerShell 時沒有 `uname`,改以 PowerShell 印出標記。
    /// 只寫標記本身(`Out.Write` 不加 `\r\n`)。
    public static let windowsProbe = encodedCommand("$ProgressPreference='SilentlyContinue';[Console]::Out.Write('\(windowsMarker)')")
    package static let windowsMarker = "purrdr-windows"

    /// 包好的完整指令。
    public static func encodedCommand(_ script: String) -> String {
        var bytes = Data()
        for unit in script.utf16 {
            bytes.append(UInt8(unit & 0xFF))
            bytes.append(UInt8(unit >> 8))
        }
        return launcher + bytes.base64EncodedString()
    }

    /// `encodedCommand` 的反向(測試與錯誤訊息用);不是這種指令回 `nil`。
    public static func script(inEncodedCommand command: String) -> String? {
        guard command.hasPrefix(launcher), let bytes = Data(base64Encoded: String(command.dropFirst(launcher.count))),
              bytes.count.isMultiple(of: 2) else { return nil }
        let units = stride(from: 0, to: bytes.count, by: 2).map { UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8 }
        return String(decoding: units, as: UTF16.self)
    }

    /// PowerShell 的字串常值：單引號包住，內部單引號寫成兩個。單引號字串裡 `$` 與反引號都不展開。
    /// PowerShell 把彎引號(U+2018–U+201B)也當單引號，一樣要重複。
    public static func quote(_ text: String) -> String {
        var quoted = "'"
        for character in text {
            quoted.append(character)
            if singleQuotes.contains(character) { quoted.append(character) }
        }
        return quoted + "'"
    }

    static let singleQuotes: Set<Character> = ["'", "\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}"]
}
