import Testing
@testable import PurrdrCore

/// 0.50.2 熱修(#492)的意圖:app 不在前景時不排程捲動;排程的重試有總量上限,
/// 不因為列表高度反覆變動(版面事件)而無限重設。
@Suite("聊天列表捲動排程政策")
struct ChatListFlushPolicyTests {
    @Test("不在前景:不排程、也不執行捲動;回前景後才恢復")
    func inactiveSchedulesNothing() {
        var policy = ChatListFlushPolicy()
        policy.isSceneActive = false
        let scheduledEvent = policy.schedule(.event)
        let scheduledLayout = policy.schedule(.layout)
        #expect(!scheduledEvent)
        #expect(!scheduledLayout)
        #expect(!policy.mayRunFlush)
        #expect(policy.retriesLeft == 0)
        policy.isSceneActive = true
        #expect(policy.mayRunFlush)
        let resumed = policy.schedule(.event)
        #expect(resumed)
    }

    @Test("內容、使用者操作等事件給一份重試額度;版面(高度改變)不會重新補滿")
    func layoutNeverRefillsRetries() {
        var policy = ChatListFlushPolicy()
        let scheduled = policy.schedule(.event)
        #expect(scheduled)
        #expect(policy.retriesLeft == ChatListFlushPolicy.maximumRetries)
        // 重試用完。
        while policy.consumeRetry() {}
        #expect(policy.retriesLeft == 0)
        // 高度反覆改變(例如鍵盤、輸入列):仍會排一次處理,但不補額度,所以不會無限重試。
        for _ in 0..<100 {
            let scheduled = policy.schedule(.layout)
            #expect(scheduled)
        }
        #expect(policy.retriesLeft == 0)
        let retried = policy.consumeRetry()
        #expect(!retried)
    }

    @Test("總重試次數不超過上限:一個事件之後最多重試 maximumRetries 次")
    func retriesAreBounded() {
        var policy = ChatListFlushPolicy()
        _ = policy.schedule(.event)
        var count = 0
        while policy.consumeRetry() { count += 1 }
        #expect(count == ChatListFlushPolicy.maximumRetries)
    }
}
