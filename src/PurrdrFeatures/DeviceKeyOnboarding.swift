import Foundation
import PurrdrCore

/// 新增主機引導與主機編輯頁共用的「這支裝置的金鑰」做法(#346):取得公鑰、產生把公鑰加進電腦的指令。
/// 兩邊各自維護時,引導版少了失敗說明、指令清單也各寫一份。
enum DeviceKeyOnboarding {
    /// 取得這支裝置的公鑰(第一次會在 Secure Enclave 產生金鑰),在背景執行。
    static func load(from credentials: HostCredentials) async -> Result<SSHPublicKey, any Error> {
        let deviceKey = credentials.deviceKey
        return await Task.detached { Result { try deviceKey.publicKey() } }.value
    }

    /// 「在那台電腦開終端機、貼上這一行、按 Enter」:Windows 是 PowerShell,其他是 Terminal。
    static func pasteLineText(onWindows: Bool) -> String {
        onWindows
            ? String(localized: "On that computer, open PowerShell, paste this line, then press Enter.")
            : String(localized: "On that computer, open Terminal, paste this line, then press Enter.")
    }

    /// 把公鑰加進電腦的指令步驟。`system` 已知時只給那個系統的(Windows 另附管理員帳號的版本);
    /// 還不知道系統(主機編輯頁)時各系統都給,由使用者挑自己的。
    static func commands(for key: SSHPublicKey, system: HostOperatingSystem?) -> [AddHostGuideInstruction] {
        switch system {
        case .windows?:
            [
                AddHostGuideInstruction(
                    text: pasteLineText(onWindows: true), command: AuthorizedKeyCommand.command(adding: key, on: .windows)),
                AddHostGuideInstruction(
                    text: String(localized: "If this account is an administrator, open PowerShell as an administrator and paste this line instead."),
                    command: AuthorizedKeyCommand.command(adding: key, on: .windowsAdministrator)),
            ]
        case .macOS?, .linux?:
            [AddHostGuideInstruction(
                text: pasteLineText(onWindows: false), command: AuthorizedKeyCommand.command(adding: key, on: .macOSAndLinux))]
        case nil:
            [
                AddHostGuideInstruction(
                    text: String(localized: "On a Mac or Linux, paste this line and press Enter."),
                    command: AuthorizedKeyCommand.command(adding: key, on: .macOSAndLinux)),
                AddHostGuideInstruction(
                    text: String(localized: "On Windows, paste this line instead and press Enter."),
                    command: AuthorizedKeyCommand.command(adding: key, on: .windows)),
                AddHostGuideInstruction(
                    text: String(localized: "On Windows, if this account is an administrator, open PowerShell as an administrator and paste this line instead."),
                    command: AuthorizedKeyCommand.command(adding: key, on: .windowsAdministrator)),
            ]
        }
    }
}
