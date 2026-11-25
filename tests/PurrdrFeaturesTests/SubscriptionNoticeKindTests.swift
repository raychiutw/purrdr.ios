import Testing

@testable import PurrdrFeatures

/// 訂閱結果通知(#625、spec #612):純告知的顯示在頁內,需要使用者確認、決定或出錯的才用 alert。
@Suite("訂閱結果通知的呈現方式")
struct SubscriptionNoticeKindTests {
    @Test("純告知(開通、恢復、沒有可恢復、等待核准、尚未送達、轉移完成)改顯示在頁內")
    func informationalNoticesAreShownInline() {
        let informational: [SubscriptionNotice] = [.welcome, .restored, .nothingToRestore, .pending, .purchaseNotDelivered, .transferred]
        for notice in informational {
            #expect(notice.isInformational, "\(notice)")
        }
    }

    @Test("失敗與需要決定的(要先登入、屬於另一個會員、不能轉移或購買、本人確認失敗、其他錯誤)保留 alert")
    func noticesNeedingAttentionKeepAlert() {
        let attention: [SubscriptionNotice] = [.signInRequired, .inUseByAnotherMember, .transferBlocked, .alreadySubscribed, .ownerNotConfirmed, .failed]
        for notice in attention {
            #expect(!notice.isInformational, "\(notice)")
        }
    }
}
