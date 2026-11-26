import Foundation
import PurrdrCore
import Testing

/// 往上翻只建構新頁、補讀完只重建一次(#586):次數計數器與新舊輸出等價。
@Suite("對話時間軸:往上翻增量")
struct ConversationTimelineIncrementalTests {
    /// 固定種子的簡單亂數(可重現)。
    struct Generator {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    /// 產生一串含工具呼叫／結果(可跨頁)、委派、shell 的訊息。
    static func messages(count: Int, seed: UInt64, prefix: String = "m") -> [TranscriptMessage] {
        var random = Generator(state: seed)
        var openCalls: [String] = []
        var messages: [TranscriptMessage] = []
        for index in 0..<count {
            let id = "\(prefix)\(index)"
            let parts: [TranscriptPart]
            var role = TranscriptMessage.Role.assistant
            switch random.next(12) {
            case 0, 1:
                role = .user
                parts = [.text("u\(index)")]
            case 2:
                parts = [.text("a\(index)")]
            case 3:
                parts = [.thinking("t\(index)")]
            case 4, 5, 6:
                let call = "\(prefix)c\(index)"
                openCalls.append(call)
                parts = [.toolCall(id: call, name: ["Bash", "Read", "Edit", "Grep"][random.next(4)], input: "x", path: "/p/\(index)")]
            case 7, 8:
                role = .user
                if openCalls.isEmpty {
                    parts = [.toolResult(callID: "gone\(index)", text: "orphan", isError: false)]
                } else {
                    let call = openCalls.remove(at: random.next(openCalls.count))
                    parts = [.toolResult(callID: call, text: "ok \(call)", isError: random.next(5) == 0)]
                }
            case 9:
                let call = "\(prefix)d\(index)"
                openCalls.append(call)
                parts = [.delegation(DelegationCall(kind: .subagent, callID: call, title: "sub\(index)"))]
            case 10:
                role = .user
                parts = [.shellInput("ls \(index)")]
            default:
                role = .user
                parts = [.shellOutput(ShellOutput(stdout: "out\(index)", stderr: ""))]
            }
            messages.append(TranscriptMessage(id: id, role: role, date: Date(timeIntervalSince1970: Double(index)), parts: parts))
        }
        return messages
    }

    /// 工具串的 id 沿用「既有列」的身分(設計如此),比對內容時先抹平。
    static func normalized(_ items: [ConversationItem]) -> [ConversationItem] {
        items.map { item in
            guard case .toolRun(var run) = item else { return item }
            run.id = run.steps[0].id
            run.expansionID = run.steps[0].id
            return .toolRun(run)
        }
    }

    /// 之後接上的新訊息:結果指回全部既有的呼叫(含較舊頁的)。
    static func laterMessages(after all: [TranscriptMessage]) -> [TranscriptMessage] {
        let calls = all.flatMap { message -> [String] in
            message.parts.compactMap { part in
                switch part {
                case .toolCall(let id?, _, _, _): id
                case .delegation(let call): call.callID
                default: nil
                }
            }
        }
        var messages: [TranscriptMessage] = []
        for (index, call) in calls.enumerated() where index % 3 == 0 {
            messages.append(TranscriptMessage(id: "late\(index)", role: .user, date: nil, parts: [.toolResult(callID: call, text: "late \(call)", isError: false)]))
            messages.append(TranscriptMessage(id: "step\(index)", role: .assistant, date: nil, parts: [.thinking("later \(index)")]))
        }
        return messages
    }

    @Test("往上翻接上舊頁,輸出等於整份重建(多組種子、各種切點、之後再接新訊息)")
    func prependEquivalentToFullRebuild() {
        for seed in UInt64(1)...60 {
            let all = Self.messages(count: 70, seed: seed)
            let later = Self.laterMessages(after: all)
            let tail = 15 + Int(seed % 20)
            let page = 5 + Int(seed % 13)

            var expected = ConversationTimeline()
            _ = expected.reset(all)
            _ = expected.append(later)

            var actual = ConversationTimeline()
            _ = actual.reset(Array(all[(all.count - tail)...]))
            var end = all.count - tail
            while end > 0 {
                let start = max(0, end - page)
                _ = actual.prependOlder(Array(all[start..<end]))
                end = start
            }
            _ = actual.append(later)

            #expect(Self.normalized(actual.items) == Self.normalized(expected.items), "seed \(seed)")
            #expect(actual.rows.count == expected.rows.count, "seed \(seed)")
        }
    }

    @Test("連翻多頁:每頁只建構新頁的訊息,不重跑全部")
    func prependingBuildsOnlyTheNewPage() {
        // 每頁以一則使用者訊息開頭、不留跨頁相依,走增量路徑。
        let all = (0..<400).map { index in
            TranscriptMessage(id: "m\(index)", role: index % 2 == 0 ? .user : .assistant, date: nil, parts: [.text("t\(index)")])
        }
        var timeline = ConversationTimeline()
        _ = timeline.reset(Array(all[300...]))
        #expect(timeline.builtMessageCount == 100)
        for page in 0..<3 {
            let end = 300 - page * 100
            _ = timeline.prependOlder(Array(all[(end - 100)..<end]))
        }
        // 舊實作每頁重建全部:100 + 200 + 300 + 400 = 1000。
        #expect(timeline.builtMessageCount == 400, "實際 \(timeline.builtMessageCount)")
        #expect(timeline.items.count == 400)
    }

    @Test("有跨頁工具呼叫與結果時,翻頁仍只建構新頁(結果補回舊頁的呼叫)")
    func crossPageToolResultsAreResolvedWithoutRebuilding() {
        var all: [TranscriptMessage] = []
        for index in 0..<120 {
            all.append(TranscriptMessage(id: "c\(index)", role: .assistant, date: nil, parts: [.toolCall(id: "k\(index)", name: "Bash", input: "x", path: nil)]))
            all.append(TranscriptMessage(id: "r\(index)", role: .user, date: nil, parts: [.toolResult(callID: "k\(index)", text: "ok", isError: false)]))
            all.append(TranscriptMessage(id: "a\(index)", role: .assistant, date: nil, parts: [.text("done")]))
        }
        var expected = ConversationTimeline()
        _ = expected.reset(all)

        var timeline = ConversationTimeline()
        // 切在呼叫與結果之間:尾端第一則是 r 結果,呼叫在舊頁。
        let tailStart = all.count - 100 + 1
        _ = timeline.reset(Array(all[tailStart...]))
        var end = tailStart
        while end > 0 {
            let start = max(0, end - 100 + 1)
            _ = timeline.prependOlder(Array(all[start..<end]))
            end = start
        }
        #expect(Self.normalized(timeline.items) == Self.normalized(expected.items))
        #expect(timeline.builtMessageCount < all.count + 60, "實際 \(timeline.builtMessageCount)")
    }
}

/// 附加新訊息只重算被改動的那一段(#586):重算列數計數,與整份重建的輸出等價。
@Suite("對話時間軸:附加增量")
struct ConversationTimelineAppendTests {
    @Test("長對話附加一則:只重算尾端幾列,不走訪全部")
    func appendRecomputesOnlyTheTail() {
        let all = (0..<1_000).map { index in
            TranscriptMessage(id: "m\(index)", role: index % 2 == 0 ? .user : .assistant, date: nil, parts: [.text("t\(index)")])
        }
        var timeline = ConversationTimeline()
        _ = timeline.reset(Array(all[..<999]))
        let before = timeline.recomputedRowCount
        let update = timeline.append([all[999]])
        #expect(timeline.recomputedRowCount - before <= 2, "實際 \(timeline.recomputedRowCount - before)")
        #expect(update.changes.count == 1)
        #expect(timeline.rows.count == 1_000)
    }

    @Test("隨機訊息(含跨頁工具結果)逐批附加,項目與列數和一次整份重建相同")
    func incrementalAppendEqualsRebuild() {
        for seed in 1...20 as ClosedRange<UInt64> {
            let all = ConversationTimelineIncrementalTests.messages(count: 120, seed: seed)
            var incremental = ConversationTimeline()
            var start = 0
            var random = ConversationTimelineIncrementalTests.Generator(state: seed &+ 99)
            while start < all.count {
                let end = min(all.count, start + 1 + random.next(6))
                _ = incremental.append(Array(all[start..<end]))
                start = end
            }
            var whole = ConversationTimeline()
            _ = whole.reset(all)
            #expect(ConversationTimelineIncrementalTests.normalized(incremental.items) == ConversationTimelineIncrementalTests.normalized(whole.items), "seed \(seed)")
            #expect(incremental.rows.count == whole.rows.count, "seed \(seed)")
            #expect(incremental.rows.map { $0.item } == incremental.items.map { Optional($0) }, "seed \(seed)")
        }
    }
}
