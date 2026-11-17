import Foundation
import PurrdrAgentFeatures
import PurrdrFeatures
import Testing

/// 多個視窗看同一份 Agent 列表時，即時更新只跑一份(#31):最後一個看的視窗離開才停。
@MainActor
@Suite("即時更新在視窗間共用")
struct SharedRunTests {
    /// 記錄工作開始與被取消的次數。工作本身一直等到被取消。
    @MainActor
    final class Work {
        var started = 0
        var cancelled = 0

        func run() async {
            started += 1
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
            }
            cancelled += 1
        }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition())
    }

    @Test("兩個視窗同時看：工作只開始一次")
    func twoViewersStartWorkOnce() async throws {
        let work = Work()
        let shared = SharedRun { await work.run() }

        let first = Task { await shared.attach() }
        let second = Task { await shared.attach() }
        // 工作在自己的 task 裡開始：等它開始後再多等一下，確認沒有第二份。
        try await waitUntil { shared.viewers == 2 && work.started >= 1 }
        try await Task.sleep(for: .milliseconds(30))

        #expect(work.started == 1)
        first.cancel()
        second.cancel()
        try await waitUntil { work.cancelled == 1 }
    }

    @Test("一個視窗離開，另一個還在看：工作繼續;最後一個離開才取消")
    func workStopsWhenLastViewerLeaves() async throws {
        let work = Work()
        let shared = SharedRun { await work.run() }
        let first = Task { await shared.attach() }
        let second = Task { await shared.attach() }
        try await waitUntil { shared.viewers == 2 }

        first.cancel()
        try await waitUntil { shared.viewers == 1 }
        try await Task.sleep(for: .milliseconds(30))
        #expect(work.cancelled == 0)

        second.cancel()
        try await waitUntil { work.cancelled == 1 }
        #expect(shared.viewers == 0)
    }

    @Test("全部離開後又有視窗來看：重新開始工作")
    func restartsAfterAllViewersLeft() async throws {
        let work = Work()
        let shared = SharedRun { await work.run() }
        let first = Task { await shared.attach() }
        try await waitUntil { work.started == 1 }
        first.cancel()
        try await waitUntil { work.cancelled == 1 }

        let again = Task { await shared.attach() }
        try await waitUntil { work.started == 2 }
        again.cancel()
        try await waitUntil { work.cancelled == 2 }
    }
}
