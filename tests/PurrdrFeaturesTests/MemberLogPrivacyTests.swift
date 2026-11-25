import PurrdrCore
import PurrdrFeatures
import Testing

/// 會員診斷紀錄的隱私等級(#580):帶後台回傳碼或原因的事件標成 private。
@Suite("會員紀錄的隱私")
struct MemberLogPrivacyTests {
    @Test("固定文字的事件 public;帶後台回傳碼或原因的事件 private")
    func sensitivity() {
        for event in [MemberDiagnosticEvent.signedIn, .refreshed, .tokenStorageFailed, .cleared] {
            #expect(MemberLog.isPrivate(event) == false)
        }
        #expect(MemberLog.isPrivate(.refreshRejected(code: "invalid_refresh_token")))
        #expect(MemberLog.isPrivate(.refreshUnavailable(reason: "503")))
    }
}
