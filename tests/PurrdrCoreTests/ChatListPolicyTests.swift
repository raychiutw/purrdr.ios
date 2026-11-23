import Foundation
import PurrdrCore
import Testing

/// 聊天列表的初次定位、套用內容的時機與延伸到玻璃底下的 inset 計算(#487 補件)。
@Suite("聊天列表:初次定位、延後套用、inset")
struct ChatListPolicyTests {
    // MARK: - 初次定位

    @Test("打開時捲到底的時機是第一次有內容的套用,空內容的第一次套用不算")
    func initialScrollWaitsForFirstContent() {
        #expect(!ChatListInitialPosition.needsScroll(hadContent: false, hasContent: false))
        #expect(ChatListInitialPosition.needsScroll(hadContent: false, hasContent: true))
        #expect(!ChatListInitialPosition.needsScroll(hadContent: true, hasContent: true))
        #expect(!ChatListInitialPosition.needsScroll(hadContent: true, hasContent: false))
    }

    // MARK: - 延後套用

    @Test("拖曳、鍵盤動畫、選單開著時延後套用內容;第一次套用與一般狀態不延後")
    func applyIsDeferredOnlyWhileUnsafe() {
        #expect(!ChatListApplyGate.shouldDefer(isFirstApply: false, isUserDriven: false, isKeyboardAnimating: false, isMenuOpen: false))
        #expect(ChatListApplyGate.shouldDefer(isFirstApply: false, isUserDriven: true, isKeyboardAnimating: false, isMenuOpen: false))
        #expect(ChatListApplyGate.shouldDefer(isFirstApply: false, isUserDriven: false, isKeyboardAnimating: true, isMenuOpen: false))
        #expect(ChatListApplyGate.shouldDefer(isFirstApply: false, isUserDriven: false, isKeyboardAnimating: false, isMenuOpen: true))
        #expect(!ChatListApplyGate.shouldDefer(isFirstApply: true, isUserDriven: true, isKeyboardAnimating: true, isMenuOpen: true))
    }

    // MARK: - inset

    @Test("列表延伸到安全區域外:上下 inset 是列表與安全區域框的差")
    func insetsAreDifferenceBetweenListAndSafeFrames() {
        let insets = ChatListInsetMath.insets(listMinY: 0, listMaxY: 852, safeMinY: 103, safeMaxY: 740)
        #expect(insets.top == 103)
        #expect(insets.bottom == 112)
    }

    @Test("列表與安全區域框一樣大:沒有 inset;安全區域框超出列表時不出現負值")
    func insetsNeverNegative() {
        let same = ChatListInsetMath.insets(listMinY: 100, listMaxY: 700, safeMinY: 100, safeMaxY: 700)
        #expect(same.top == 0 && same.bottom == 0)
        let outside = ChatListInsetMath.insets(listMinY: 100, listMaxY: 700, safeMinY: 50, safeMaxY: 750)
        #expect(outside.top == 0 && outside.bottom == 0)
    }

    // MARK: - 最近開過的聊天(記憶體快取)

    @Test("最近快取:放入後取得,超過上限淘汰最久沒用的")
    func recentCacheEvictsLeastRecentlyUsed() {
        var cache = RecentCache<Int>(capacity: 2)
        cache.set(1, for: "a")
        cache.set(2, for: "b")
        _ = cache.value(for: "a")
        cache.set(3, for: "c")

        #expect(cache.value(for: "a") == 1)
        #expect(cache.value(for: "b") == nil)
        #expect(cache.value(for: "c") == 3)
    }

    @Test("最近快取:覆寫同一個 key 不增加數量;移除單筆與依前綴移除")
    func recentCacheOverwriteAndRemoval() {
        var cache = RecentCache<Int>(capacity: 3)
        cache.set(1, for: "h1/a")
        cache.set(2, for: "h1/a")
        cache.set(3, for: "h1/b")
        cache.set(4, for: "h2/a")
        #expect(cache.count == 3)
        #expect(cache.value(for: "h1/a") == 2)

        cache.remove("h2/a")
        #expect(cache.value(for: "h2/a") == nil)

        cache.removeAll(keyPrefix: "h1/")
        #expect(cache.count == 0)
    }

    @Test("內容套用批次:第一次與間隔夠久立刻套用,否則等到滿間隔")
    func applyBatchDelay() {
        #expect(ChatListApplyBatch.delay(now: 10, lastApplyAt: nil, interval: 0.1) == 0)
        #expect(ChatListApplyBatch.delay(now: 10.2, lastApplyAt: 10, interval: 0.1) == 0)
        let wait = ChatListApplyBatch.delay(now: 10.04, lastApplyAt: 10, interval: 0.1)
        #expect(abs(wait - 0.06) < 1e-9)
    }
}
