import PurrdrCore
import PurrdrFeatures
import PurrdrSSH
import Testing

/// SSH 連線診斷事件的紀錄文字(#133):在 Console 以 subsystem `com.raychiu.purrdr`、category `ssh` 篩選時看得懂。
@Suite("SSH 連線紀錄")
struct SSHConnectionLogTests {
    @Test("每種事件都寫出撥號序號與原因;連線壽命以秒表示")
    func messages() {
        #expect(SSHConnectionLog.message(for: .connected(dial: 3)) == "dial 3 connected")
        #expect(SSHConnectionLog.message(for: .dialFailed(dial: 4, error: .timedOut)) == "dial 4 failed: timedOut")
        #expect(
            SSHConnectionLog.message(for: .dropped(dial: 3, reason: .keepaliveTimeout, lifetime: .milliseconds(912_400)))
                == "dial 3 dropped after 912s: keepalive timeout")
        #expect(
            SSHConnectionLog.message(for: .dropped(dial: 5, reason: .channelOpenTimeout, lifetime: .seconds(20)))
                == "dial 5 dropped after 20s: channel open timeout")
        #expect(
            SSHConnectionLog.message(for: .dropped(dial: 6, reason: .disconnectRequested, lifetime: .seconds(1)))
                == "dial 6 dropped after 1s: disconnect requested by the app")
        #expect(
            SSHConnectionLog.message(for: .dropped(dial: 7, reason: .networkError("Connection reset by peer"), lifetime: .seconds(2)))
                == "dial 7 dropped after 2s: network error: Connection reset by peer")
        #expect(
            SSHConnectionLog.message(for: .dropped(dial: 8, reason: .closedByPeer, lifetime: .seconds(3)))
                == "dial 8 dropped after 3s: closed by the host or the network")
    }
}
