import Testing

@testable import PurrdrCore

@Suite("回前景的重連策略(#550)")
struct ForegroundReconnectPolicyTests {
    @Test("背景時間不超過保留時間:沿用;超過:重撥(邊界 25 秒仍沿用)")
    func decision() {
        #expect(ForegroundReconnectPolicy.decision(backgroundSeconds: 0) == .reuse)
        #expect(ForegroundReconnectPolicy.decision(backgroundSeconds: 25) == .reuse)
        #expect(ForegroundReconnectPolicy.decision(backgroundSeconds: 25.1) == .redial)
        #expect(ForegroundReconnectPolicy.decision(backgroundSeconds: 600) == .redial)
    }

    @Test("診斷紀錄寫背景秒數與沿用／重撥")
    func logLine() {
        #expect(ForegroundReconnectPolicy.logLine(backgroundSeconds: 12.9, decision: .reuse) == "背景 12 秒，沿用")
        #expect(ForegroundReconnectPolicy.logLine(backgroundSeconds: 40, decision: .redial) == "背景 40 秒，重撥")
    }

    @Test("安靜重連:前 1.5 秒不顯示,之後連線中,10 秒起仍在連線")
    func quietReconnectDisplay() {
        #expect(ConnectingDisplayPolicy.display(elapsed: 0, isQuietReconnect: true) == .hidden)
        #expect(ConnectingDisplayPolicy.display(elapsed: 1.4, isQuietReconnect: true) == .hidden)
        #expect(ConnectingDisplayPolicy.display(elapsed: 1.5, isQuietReconnect: true) == .connecting)
        #expect(ConnectingDisplayPolicy.display(elapsed: 9.9, isQuietReconnect: true) == .connecting)
        #expect(ConnectingDisplayPolicy.display(elapsed: 10, isQuietReconnect: true) == .stillConnecting)
    }

    @Test("一般連線(不是安靜重連):立刻顯示連線中,10 秒起仍在連線")
    func normalDisplay() {
        #expect(ConnectingDisplayPolicy.display(elapsed: 0, isQuietReconnect: false) == .connecting)
        #expect(ConnectingDisplayPolicy.display(elapsed: 10, isQuietReconnect: false) == .stillConnecting)
    }
}
