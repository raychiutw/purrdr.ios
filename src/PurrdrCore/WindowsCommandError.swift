import Foundation

/// Windows 主機做不到的指令。
public enum WindowsCommandError: Error, Equatable {
    /// 這個指令或功能在 Windows 主機沒有 PowerShell 版本(附原本的 POSIX 指令;功能層面目前只有 Codex 啟動器，附路徑)。
    case unsupported(String)
    /// 包好的指令超過 cmd 的命令列上限(8,191 字元)。
    case commandTooLong
}
