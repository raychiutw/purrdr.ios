import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 喚醒探測(行為規格 §7.5):背景太久回前景，先跑一個無害指令，期限內沒結束就丟棄連線。
@Suite("喚醒探測")
struct WakeProbeTests {
    @Test("連線健康：無害指令(true)結束，不丟棄連線")
    func healthyConnectionIsKept() async {
        let host = FakeHost()
        await host.expect(WakeProbe.command, reply: FakeReply())

        let alive = await WakeProbe(channel: host, sleep: { _ in try await Task.sleep(for: .seconds(30)) }).run()

        #expect(alive)
        #expect(await host.disconnectCount == 0)
        #expect(await host.executions.map(\.command) == ["true"])
    }

    @Test("掛起期間死掉的連線：期限(3 秒)到還沒結束 → 丟棄連線，探測本身也關掉")
    func hungConnectionIsDropped() async {
        let host = FakeHost()
        await host.expect(WakeProbe.command, reply: FakeReply(keepsOpen: true))
        let waited = Waited()

        let alive = await WakeProbe(channel: host, sleep: { await waited.record($0) }).run()

        #expect(!alive)
        #expect(await waited.durations == [.seconds(3)])
        #expect(await host.disconnectCount == 1)
        // 期限到時立刻返回，探測的通道在背景關閉。
        #expect(await host.waitUntilClosed(execution: 0))
    }

    @Test("連線層錯誤 → 丟棄連線(下一個指令重新撥號)")
    func connectionErrorDropsConnection() async {
        let host = FakeHost()
        await host.failConnection(with: SSHConnectionError.connectionLost)

        let alive = await WakeProbe(channel: host, sleep: { _ in try await Task.sleep(for: .seconds(30)) }).run()

        #expect(!alive)
        #expect(await host.disconnectCount == 1)
    }
}

actor Waited {
    private(set) var durations: [Duration] = []
    func record(_ duration: Duration) { durations.append(duration) }
}
