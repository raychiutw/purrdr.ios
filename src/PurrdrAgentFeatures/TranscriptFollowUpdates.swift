import PurrdrCore

/// 套用對話紀錄追蹤事件(聊天與 subagent 畫面共用,#165):新增交給 `appended`,接不上時交給 `replaced`(重讀視窗)後結束。
@MainActor
enum TranscriptFollowUpdates {
    /// 讀到串流結束、`isCurrent()` 不再成立(換了 session 等)或接不上為止。
    ///
    /// - Parameter afterEach: 每則事件套用後、仍是目前的追蹤時執行(例如存快取)。
    /// - Returns: 是否因接不上而重讀了視窗(呼叫端從新游標再追蹤)。取消與讀取失敗照原樣丟出。
    static func apply(
        _ events: AsyncThrowingStream<TranscriptFollowEvent, any Error>,
        isCurrent: () -> Bool,
        appended: (TranscriptChunk) async -> Void,
        replaced: (_ size: Int) async throws -> Void,
        afterEach: () async -> Void = {}
    ) async throws -> Bool {
        for try await event in events {
            guard isCurrent() else { return false }
            let isReplaced: Bool
            switch event {
            case .appended(let chunk):
                await appended(chunk)
                isReplaced = false
            case .replaced(let size):
                try await replaced(size)
                isReplaced = true
            }
            guard isCurrent() else { return isReplaced }
            await afterEach()
            if isReplaced { return true }
        }
        return false
    }
}
