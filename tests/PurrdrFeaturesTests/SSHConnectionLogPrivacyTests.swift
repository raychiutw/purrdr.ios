import PurrdrFeatures
import PurrdrSSH
import Testing

/// 診斷紀錄的隱私等級(#580):帶錯誤描述、原因等動態內容的事件在系統紀錄裡標成 private。
@Suite("SSH 連線紀錄的隱私")
struct SSHConnectionLogPrivacyTests {
    @Test("連線成功只有撥號序號,public;失敗與中斷帶錯誤描述,private")
    func sensitivity() {
        #expect(SSHConnectionLog.isPrivate(.connected(dial: 1)) == false)
        #expect(SSHConnectionLog.isPrivate(.dialFailed(dial: 1, error: .timedOut)))
        #expect(SSHConnectionLog.isPrivate(.dropped(dial: 1, reason: .networkError("x"), lifetime: .seconds(1))))
        #expect(SSHConnectionLog.isPrivate(.dropped(dial: 1, reason: .keepaliveTimeout, lifetime: .seconds(1))))
    }
}
