import PurrdrAgentFeatures
import Testing

@Suite("唯讀裝置的切換入口")
struct ReadOnlyDeviceStateTests {
    @Test("輪詢回報唯讀、回答被拒、送出被拒都切成唯讀", arguments: [
        ReadOnlyDeviceState.Signal.reported(true), .answerRejected, .sendRejected,
    ])
    func signalsSwitchToReadOnly(signal: ReadOnlyDeviceState.Signal) {
        var state = ReadOnlyDeviceState()
        state.observe(signal)
        #expect(state.isReadOnly)
    }

    @Test("輪詢回報可寫入不切換")
    func writableReportKeepsWritable() {
        var state = ReadOnlyDeviceState()
        state.observe(.reported(false))
        #expect(!state.isReadOnly)
    }

    @Test("判定為唯讀後維持,輪詢回報可寫入也不解除")
    func staysReadOnly() {
        var state = ReadOnlyDeviceState()
        state.observe(.sendRejected)
        state.observe(.reported(false))
        #expect(state.isReadOnly)
    }
}
