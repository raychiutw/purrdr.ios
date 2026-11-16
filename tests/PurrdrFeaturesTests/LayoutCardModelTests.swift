import Foundation
import PurrdrFeatures
import Testing

/// iPad 版面圖浮動卡片(#31 補充、#37 故事 22、行為規格 F4):
/// 指標停在版面圖按鈕上 300ms 出現、離開按鈕與卡片 200ms 消失;點按鈕釘住，釘住後按「關閉」、點背景或 Esc 才關。
@MainActor
@Suite("版面圖浮動卡片")
struct LayoutCardModelTests {
    /// 手動推進的時鐘：記下每次等待的長度，`advance()` 才讓等待結束。
    @MainActor
    final class ManualClock {
        private(set) var requested: [Duration] = []
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func sleep(_ duration: Duration) async {
            requested.append(duration)
            await withCheckedContinuation { waiting.append($0) }
        }

        /// 讓目前所有的等待結束，並等它們後續的狀態改變做完。
        func advance() async {
            let resumed = waiting
            waiting.removeAll()
            resumed.forEach { $0.resume() }
            for _ in 0..<20 { await Task.yield() }
        }

        var pendingCount: Int { waiting.count }
    }

    private func makeModel() -> (LayoutCardModel, ManualClock) {
        let clock = ManualClock()
        let model = LayoutCardModel { await clock.sleep($0) }
        return (model, clock)
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    @Test("指標停在版面圖按鈕上 300ms 後出現卡片(預覽)")
    func hoverShowsPeekAfterDelay() async {
        let (model, clock) = makeModel()

        Task { await model.pointer(overButton: "w1", isInside: true) }
        await settle()
        #expect(model.state == .hidden)
        #expect(clock.requested == [.milliseconds(300)])

        await clock.advance()
        #expect(model.state == .peeking(workspaceID: "w1"))
    }

    @Test("不到 300ms 就移開：卡片不出現")
    func briefHoverDoesNotShow() async {
        let (model, clock) = makeModel()

        Task { await model.pointer(overButton: "w1", isInside: true) }
        await settle()
        Task { await model.pointer(overButton: "w1", isInside: false) }
        await settle()
        await clock.advance()
        await clock.advance()

        #expect(model.state == .hidden)
    }

    @Test("預覽中移開按鈕 200ms 後消失")
    func leavingHidesPeekAfterDelay() async {
        let (model, clock) = makeModel()
        Task { await model.pointer(overButton: "w1", isInside: true) }
        await settle()
        await clock.advance()

        Task { await model.pointer(overButton: "w1", isInside: false) }
        await settle()
        #expect(clock.requested.last == .milliseconds(200))
        #expect(model.state == .peeking(workspaceID: "w1"))

        await clock.advance()
        #expect(model.state == .hidden)
    }

    @Test("從按鈕移到卡片上：卡片留著;離開卡片 200ms 後消失")
    func movingOntoCardKeepsPeek() async {
        let (model, clock) = makeModel()
        Task { await model.pointer(overButton: "w1", isInside: true) }
        await settle()
        await clock.advance()

        Task { await model.pointer(overButton: "w1", isInside: false) }
        await settle()
        Task { await model.pointer(overCard: true) }
        await settle()
        await clock.advance()
        #expect(model.state == .peeking(workspaceID: "w1"))

        Task { await model.pointer(overCard: false) }
        await settle()
        await clock.advance()
        #expect(model.state == .hidden)
    }

    @Test("點版面圖按鈕：立刻出現並釘住，指標移開也不消失")
    func tapPins() async {
        let (model, clock) = makeModel()

        model.tap("w1")
        #expect(model.state == .pinned(workspaceID: "w1"))

        Task { await model.pointer(overButton: "w1", isInside: false) }
        await settle()
        await clock.advance()
        #expect(model.state == .pinned(workspaceID: "w1"))
    }

    @Test("預覽中點按鈕或在卡片上按下：釘住")
    func tapWhilePeekingPins() async {
        let (model, clock) = makeModel()
        Task { await model.pointer(overButton: "w2", isInside: true) }
        await settle()
        await clock.advance()

        model.pin()

        #expect(model.state == .pinned(workspaceID: "w2"))
    }

    @Test("釘住後按「關閉」、點背景或 Esc:關閉")
    func closeHidesPinnedCard() {
        let (model, _) = makeModel()
        model.tap("w1")

        model.close()

        #expect(model.state == .hidden)
    }

    @Test("釘住時指標停在別的 workspace 的按鈕上：不換成預覽")
    func hoverAnotherWhilePinnedKeepsPinned() async {
        let (model, clock) = makeModel()
        model.tap("w1")

        Task { await model.pointer(overButton: "w2", isInside: true) }
        await settle()
        await clock.advance()

        #expect(model.state == .pinned(workspaceID: "w1"))
    }

    @Test("釘住時點別的 workspace 的按鈕：改釘那一個")
    func tapAnotherWhilePinnedSwitches() {
        let (model, _) = makeModel()
        model.tap("w1")

        model.tap("w2")

        #expect(model.state == .pinned(workspaceID: "w2"))
    }
}
