import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 假主機本身的行為：其他測試都靠它斷言 app 送出的指令，它自己不能放水。
@Suite("假主機")
struct FakeHostTests {
    @Test("沒有預期的指令一律失敗，不默默回空結果")
    func unexpectedCommandFails() async {
        let host = FakeHost()
        await host.expect("herdr --version", reply: FakeReply(stdout: Data("herdr 0.9.5\n".utf8)))

        await #expect(throws: FakeHostError.unexpectedCommand("rm -rf ~")) {
            _ = try await host.execute("rm -rf ~")
        }
        #expect(await host.executions.isEmpty)
        #expect(await host.unmetExpectations == ["herdr --version"])
    }

    @Test("PTY:記錄開啟參數、輸入與尺寸變更，並回放預期的畫面")
    func ptyRecordsInputAndReplaysOutput() async throws {
        let host = FakeHost()
        let request = PTYRequest(columns: 80, rows: 24)
        await host.expectPTY(request, output: Data("demo@host ~ % ".utf8))

        let pty = try await host.openPTY(request)
        try await pty.write(Data("ls\r".utf8))
        try await pty.resize(columns: 100, rows: 30)
        var iterator = pty.output.makeAsyncIterator()
        let screen = try await iterator.next()
        await pty.close()

        #expect(screen == Data("demo@host ~ % ".utf8))
        #expect(await host.ptys == [
            FakeHost.PTYOpening(request: request, input: Data("ls\r".utf8), sizes: [.init(columns: 100, rows: 30)], closed: true),
        ])
    }
}
