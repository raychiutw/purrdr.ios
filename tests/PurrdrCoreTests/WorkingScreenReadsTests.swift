import Foundation
import PurrdrCore
import Testing

/// 工作中讀 pane 畫面的節奏(#204):聊天每 2 秒輪詢，工作中只隔幾輪讀一次畫面;需要你與其他狀態不受限。
@Suite("工作中讀畫面的節奏")
struct WorkingScreenReadsTests {
    static let start = Date(timeIntervalSince1970: 1_000_000)

    /// 依序在這些秒數輪詢，回傳有讀畫面的秒數。
    static func reads(polls: [(seconds: TimeInterval, isWorking: Bool)]) -> [TimeInterval] {
        var pace = WorkingScreenReads()
        return polls.filter { pace.allowsRead(isWorking: $0.isWorking, at: start.addingTimeInterval($0.seconds)) }.map(\.seconds)
    }

    @Test("工作中每 2 秒輪詢：第一輪就讀，之後每 6 秒讀一次(一分鐘 10 次，不是 30 次)")
    func workingReadsEverySixSeconds() {
        let polls = stride(from: 0.0, to: 60, by: 2).map { (seconds: $0, isWorking: true) }

        #expect(Self.reads(polls: polls) == [0, 6, 12, 18, 24, 30, 36, 42, 48, 54])
    }

    @Test("輪詢時間有誤差(早到幾百毫秒)也維持每 3 輪讀一次")
    func earlyPollsStillReadEveryThirdPoll() {
        let polls = [0, 2.1, 4.0, 5.8, 7.9, 9.9, 11.7].map { (seconds: $0, isWorking: true) }

        #expect(Self.reads(polls: polls) == [0, 5.8, 11.7])
    }

    @Test("需要你、閒置、完成時不限制(需要你每輪讀畫面的反應速度不變)")
    func otherStatusesAreNotLimited() {
        let polls = stride(from: 0.0, to: 10, by: 2).map { (seconds: $0, isWorking: false) }

        #expect(Self.reads(polls: polls) == [0, 2, 4, 6, 8])
    }

    @Test("離開工作中(例如回答完問題)再回到工作中，第一輪立刻讀，不等滿間隔")
    func reenteringWorkingReadsImmediately() {
        let polls = [(0.0, true), (2, false), (4, true), (6, true), (8, true), (10, true)].map { (seconds: $0.0, isWorking: $0.1) }

        #expect(Self.reads(polls: polls) == [0, 2, 4, 10])
    }
}
