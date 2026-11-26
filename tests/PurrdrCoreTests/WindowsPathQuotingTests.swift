import Foundation
import Testing
@testable import PurrdrCore
@testable import PurrdrSSH

/// #571 之後含反斜線的參數改用雙引號;Windows 通道解析 POSIX 指令時仍要還原出原本的 `C:\…` 路徑。
struct WindowsPathQuotingTests {
    @Test func windowsPathSurvivesQuoteAndWordSplit() {
        let path = #"C:\Users\ray\My "Docs"\it's $x"#
        let command = HerdrCommand.version(HerdrInstallation(path: path))
        let words = PosixWords.split(command.dropFirst(HerdrCommand.pathPrefix.count + 1))
        #expect(words?.contains { $0.text == path && $0.quoted } == true)
    }

    @Test func homeRelativeHerdrPathStillSplits() {
        let command = HerdrCommand.version(HerdrInstallation(path: #"~/bin\herdr"#))
        let words = PosixWords.split(command.dropFirst(HerdrCommand.pathPrefix.count + 1))
        #expect(words?.contains { $0.homeRelative && $0.text == #"bin\herdr"# } == true)
    }
}
