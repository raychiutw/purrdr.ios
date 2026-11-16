import Foundation
@testable import PurrdrCore
import PurrdrTestSupport
import Testing

/// Windows 方言的兩條實測規則(#26)。
@Suite("Windows 方言的規則")
struct WindowsScriptRulesTests {
    @Test("腳本裡的 PowerShell 函式都以 P 開頭、名稱夠長：alias 優先於函式，`rd` 會變成 Remove-Item、`ls` 會變成 Get-ChildItem")
    func functionNamesAvoidAliases() throws {
        let scripts = [
            WindowsScripts.prelude, WindowsScripts.transcriptFunctions, WindowsScripts.receive, WindowsScripts.imageUpload,
            WindowsScripts.folderUpload, WindowsScripts.folderList, WindowsScripts.newChatFolders,
        ]
        let names = scripts.flatMap { $0.matches(of: /function (\w+)/).map { String($0.output.1) } }
        #expect(names.count >= 18)
        for name in names {
            #expect(name.hasPrefix("P") && name.count >= 5, "\(name) 可能撞到內建 alias")
        }
    }

    @Test("同一個指令只送一次 EOF:stdin 腳本已送過 EOF,呼叫端再送一次不往下傳(實測第二次 EOF 會讓輸出提早斷掉)")
    func endOfInputOnlyOnce() async throws {
        let host = CountingHost()

        let session = try await WindowsHostChannel(host).execute(HostFolderCommand.list(nil))
        await session.closeStdin()
        await session.closeStdin()

        #expect(await host.closeStdinCount == 1)
    }
}

/// 數 EOF 次數的主機(指令一律開一個什麼都不回的 session)。
actor CountingHost: HostChannel {
    private(set) var closeStdinCount = 0

    func execute(_ command: String) async throws -> any ExecSession { CountingSession(host: self) }
    func openPTY(_ request: PTYRequest) async throws -> any PTYSession { throw FakeHostError.unexpectedPTY(request) }
    func countClose() { closeStdinCount += 1 }
}

struct CountingSession: ExecSession {
    let host: CountingHost
    let output = AsyncThrowingStream<ExecOutput, any Error> { $0.finish() }
    func write(_ data: Data) async throws {}
    func closeStdin() async { await host.countClose() }
    func close() async {}
}
