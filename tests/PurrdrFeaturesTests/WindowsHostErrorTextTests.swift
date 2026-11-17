import Foundation
import PurrdrAgentFeatures
import PurrdrCore
@testable import PurrdrFeatures
import Testing

/// Windows 主機(#26)的錯誤說明。
@Suite("Windows 主機的錯誤說明")
struct WindowsHostErrorTextTests {
    @Test("還沒有 Windows 版本的功能：直說，不說成連不上主機")
    func unsupportedOnWindows() {
        #expect(HostErrorText.message(for: WindowsCommandError.unsupported("sh -c …"))
            == "This isn’t available on Windows hosts yet.")
    }

    @Test("主題、用量等以 localizedDescription 顯示錯誤的地方，也說「Windows 主機還不能用」而不是型別名稱")
    func unsupportedLocalizedDescription() {
        #expect(WindowsCommandError.unsupported("sh -c …").localizedDescription == "This isn’t available on Windows hosts yet.")
    }

    @Test("不支援的作業系統：Windows 已經支援，說明裡要列出")
    func unsupportedOperatingSystem() {
        #expect(HostErrorText.message(for: HostProbeError.unsupportedOperatingSystem("SunOS"))
            == "Purrdr supports macOS, Linux, and Windows hosts.")
    }
}
