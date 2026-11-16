import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// Windows 主機的錯誤訊息給人看之前要整理(#6 待辦 5):herdr 的 Rust Debug 格式把路徑的反斜線跳脫成 `\\`,
/// PowerShell 把錯誤序列化成 CLIXML(`#< CLIXML`、`_x000D__x000A_`)。系統訊息本身已在地化，原樣保留。
/// 判斷一律靠 exit code,這裡只處理顯示。
@Suite("Windows 錯誤訊息")
struct WindowsErrorTextTests {
    @Test("herdr 的 Rust Debug 錯誤:取出 error 字串、還原反斜線，在地化的系統訊息原樣保留")
    func rustDebugError() {
        let stderr = String(decoding: Fixtures.data("windows/error.server-not-running.stderr.txt"), as: UTF8.self)

        #expect(WindowsErrorText.readable(stderr)
            == #"failed to connect to remote Herdr API socket C:\Users\demo\AppData\Roaming\herdr\sessions\purrdr-nosuch\herdr.sock: 系統找不到指定的檔案。 (os error 2)"#)
    }

    @Test("PowerShell 的 CLIXML 錯誤:只留 Error 串流的文字、換行還原、XML 實體解開")
    func powerShellCLIXML() {
        let stderr = #"#< CLIXML"# + "\r\n"
            + #"<Objs Version="1.1.0.1" xmlns="http://schemas.microsoft.com/powershell/2004/04"><Obj S="progress" RefId="0"><TN RefId="0"><T>x</T></TN></Obj>"#
            + #"<S S="Error">Get-Item : 找不到 'C:\nope' 路徑，因為它不存在。_x000D__x000A_</S><S S="Error">    + CategoryInfo : ObjectNotFound: (&lt;x&gt; &amp; y:String)_x000D__x000A_</S></Objs>"#

        #expect(WindowsErrorText.readable(stderr) == "Get-Item : 找不到 'C:\\nope' 路徑，因為它不存在。\n    + CategoryInfo : ObjectNotFound: (<x> & y:String)")
    }

    @Test("一般文字只去掉前後空白與 \\r")
    func plainText() {
        #expect(WindowsErrorText.readable("network unreachable\r\n") == "network unreachable")
    }

    @Test("Windows 主機更新失敗時，錯誤訊息整理過再給畫面")
    func updateFailureIsReadable() async {
        let host = FakeHost()
        await host.expect(HerdrCommand.operatingSystem, reply: FakeReply(stdout: Data("MINGW64_NT-10.0-19045\n".utf8)))
        await host.expect(
            PowerShell.encodedCommand(WindowsHostChannelTests.herdrScript("'update'")),
            reply: FakeReply(stderr: Data(#"Error: Custom { kind: Other, error: "download failed: C:\\Temp\\x" }"#.utf8), exitCode: 1))

        await #expect(throws: HostProbeError.updateFailed(#"download failed: C:\Temp\x"#)) {
            try await HostProbe(channel: host, herdr: HerdrInstallation()).updateHerdr()
        }
    }
}
