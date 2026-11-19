import Foundation
import PurrdrCore
import PurrdrDemo
import PurrdrSSH
import Testing

/// Demo 的「沒有網路」情境(#221,`-demoNoNetwork`):啟動就斷網，列表一開始就沒有任何列。
@Suite("Demo 主機：啟動就沒有網路")
struct DemoNoNetworkTests {
    @Test("斷網情境的延遲是 0:第一個指令就連不上，不會先讀到快照")
    func offlineFromLaunchFailsFirstCommand() async throws {
        let demo = DemoHost(scenario: .goesOffline(after: .zero, hangs: false))

        await #expect(throws: SSHConnectionError.timedOut) {
            _ = try await HerdrClient(channel: demo).snapshot()
        }
    }

    @Test("一直連不上的示範主機可以設成卡住：指令不回應，直到被取消")
    func hangingUnreachableChannelNeverAnswers() async throws {
        let attempt = Task { try await DemoUnreachableChannel(hangs: true).execute(HerdrCommand.bridge()) }
        try await Task.sleep(for: .milliseconds(200))
        attempt.cancel()

        await #expect(throws: CancellationError.self) { _ = try await attempt.value }
    }
}
