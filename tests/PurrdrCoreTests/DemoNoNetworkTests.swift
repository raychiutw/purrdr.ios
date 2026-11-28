import Foundation
import PurrdrCore
import PurrdrDemo
import PurrdrSSH
import Testing

/// Demo 的斷網情境(`-demoGoesOffline`,#219):定位對話紀錄後過了延遲,之後每個指令都連不上。
@Suite("Demo 主機：斷網")
struct DemoNoNetworkTests {
    @Test("一直連不上的示範主機:每個指令立刻以逾時失敗")
    func unreachableChannelFailsImmediately() async throws {
        await #expect(throws: SSHConnectionError.timedOut) {
            _ = try await DemoUnreachableChannel().execute(HerdrCommand.bridge())
        }
    }
}
