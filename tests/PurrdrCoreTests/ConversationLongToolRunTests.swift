import Foundation
import PurrdrCore
import Testing

/// #510:很長的工具串(補讀到 2000 則、尾端全是工具步驟)組畫面項目的成本要隨長度線性成長,
/// 而且增量追加與整批建立的摘要一致。
@Suite("對話項目:長工具串")
struct ConversationLongToolRunTests {
    static func pair(_ index: Int, failing: Bool = false) -> [TranscriptMessage] {
        [
            TranscriptMessage(id: "c\(index)", role: .assistant, date: nil, parts: [
                .toolCall(id: "t\(index)", name: index % 2 == 0 ? "Bash" : "Edit", input: "x", path: index % 2 == 0 ? nil : "/f\(index % 7)")]),
            TranscriptMessage(id: "r\(index)", role: .user, date: nil, parts: [
                .toolResult(callID: "t\(index)", text: "ok", isError: failing && index % 5 == 0)]),
        ]
    }

    static func messages(_ pairs: Int) -> [TranscriptMessage] { (0..<pairs).flatMap { pair($0, failing: true) } }

    @Test("整批建立與逐則追加的工具串摘要相同")
    func batchAndIncrementalSummariesMatch() {
        let all = Self.messages(60)
        var timeline = ConversationTimeline()
        for message in all { _ = timeline.append([message]) }
        var batched = ConversationTimeline()
        _ = batched.reset(all)
        #expect(timeline.items == batched.items)
        guard case .toolRun(let run)? = batched.items.first else { Issue.record("沒有工具串"); return }
        #expect(run.steps.count == 60)
        #expect(run.summary.failures == 12)
        #expect(run.summary.commands == 30)
        #expect(Conversation.items(from: all) == batched.items)
    }

    @Test("建立長工具串的工作量隨長度線性成長(不是平方)")
    func buildingLongToolRunScalesLinearly() {
        // 以建構器走訪步驟的次數計,不看牆鐘時間,所以不受機器負載影響。
        let small = Conversation.itemsMeasuringSummaryWork(from: Self.messages(1_000))
        let large = Conversation.itemsMeasuringSummaryWork(from: Self.messages(4_000))
        // 每個步驟只該被走訪常數次。
        #expect(small.stepsScanned <= 2 * 2_000, "1000 組走訪了 \(small.stepsScanned) 步")
        #expect(large.stepsScanned <= 2 * 8_000, "4000 組走訪了 \(large.stepsScanned) 步")
        // 線性約 4 倍,平方約 16 倍。
        let ratio = Double(large.stepsScanned) / Double(max(small.stepsScanned, 1))
        #expect(ratio < 5, "4 倍長度走訪了 \(ratio) 倍步驟")
    }
}
