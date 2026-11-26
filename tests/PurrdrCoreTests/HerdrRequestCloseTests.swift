import Foundation
@testable import PurrdrCore
@testable import PurrdrSSH
import PurrdrTestSupport
import Testing

/// 續接慢(#635):每個 herdr 請求收到第一行回應後，呼叫端不能再等通道「關閉完成」。
/// 真 SSH 的 `channel.close()` 要等主機回 CHANNEL_CLOSE(主機程序收尾多久就等多久),
/// 以前這段等待算在每個請求的耗時裡，`tab.create` 之後的 `agent.start` 因此晚了約 10 秒才送出。
@Suite("herdr 請求:不等通道關閉")
struct HerdrRequestCloseTests {
    /// 關閉要等閘門打開的通道(模擬主機收尾很慢)。
    final class SlowClosingChannel: HostChannel, @unchecked Sendable {
        let base: FakeHost
        let gate = AsyncGate()
        init(base: FakeHost) { self.base = base }

        func execute(_ command: String) async throws -> any ExecSession {
            SlowClosingSession(base: try await base.execute(command), gate: gate)
        }

        func openPTY(_ request: PTYRequest) async throws -> any PTYSession { try await base.openPTY(request) }
    }

    struct SlowClosingSession: ExecSession {
        let base: any ExecSession
        let gate: AsyncGate
        var output: AsyncThrowingStream<ExecOutput, any Error> { base.output }
        func write(_ data: Data) async throws { try await base.write(data) }
        func closeStdin() async { await base.closeStdin() }
        func close() async {
            await gate.wait()
            await base.close()
        }
    }

    actor AsyncGate {
        private var isOpen = false
        private var waiting: [CheckedContinuation<Void, Never>] = []
        func wait() async { if !isOpen { await withCheckedContinuation { waiting.append($0) } } }
        func open() {
            isOpen = true
            waiting.forEach { $0.resume() }
            waiting = []
        }
    }

    private static let reply = Data(#"{"id":"purrdr:tab.create","result":{"type":"ok"}}"#.utf8) + [0x0A]

    @Test("收到第一行回應就返回，通道在背景關閉")
    func returnsBeforeChannelCloses() async throws {
        let host = FakeHost()
        await host.expect(HerdrCommand.bridge(), reply: FakeReply(stdout: Self.reply, trigger: .afterStdinLine, keepsOpen: true))
        let channel = SlowClosingChannel(base: host)
        let connection = SSHHostConnection(channel: channel)
        let request = Data(#"{"id":"purrdr:tab.create","method":"tab.create","params":{}}"#.utf8) + [0x0A]

        let outcome = await boundedOutcome { try await connection.herdrRequest(request, deadline: .seconds(20)) }
        await channel.gate.open()

        #expect(outcome != nil, "通道還沒關閉完成，請求就卡住了(續接慢的原因)")
        #expect(await host.waitUntilClosed(execution: 0), "通道最後仍要關閉")
    }
}
