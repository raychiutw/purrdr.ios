#if os(macOS)
import Foundation
import Observation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 展開狀態的觀察範圍(#592):展開一列只讓讀那一列的觀察者失效。
@MainActor
@Suite("對話列展開的觀察範圍")
struct ConversationExpansionObservationTests {
    private func model() -> ConversationModel {
        ConversationModel(
            client: HerdrClient(connection: FakeHostConnection()), transcripts: TranscriptReader(connection: FakeHostConnection()),
            paneID: "w1:p1", knownSessionID: "s", cache: InMemoryConversationCache(), clock: TestClock().clock)
    }

    private func tracker(_ read: @escaping () -> Bool) -> ConversationObservationScopeTests.Tracker {
        let tracker = ConversationObservationScopeTests.Tracker()
        tracker.track { read() }
        return tracker
    }

    @Test("展開 A 列:讀 B 列的觀察者不失效,讀 A 列的失效")
    func expandingOneRowLeavesOthersAlone() {
        let model = model()
        let a = tracker { model.isExpanded(rowID: "a") }
        let b = tracker { model.isExpanded(rowID: "b") }
        let aPart = tracker { model.isExpanded(rowID: "a", partID: "p") }
        let bPart = tracker { model.isExpanded(rowID: "b", partID: "p") }

        model.setExpanded(true, rowID: "a")

        #expect(model.isExpanded(rowID: "a"))
        #expect(a.fired)
        #expect(!b.fired)
        #expect(!aPart.fired)
        #expect(!bPart.fired)
    }

    @Test("展開 A 列的子項:只有讀 A 列同一子項的失效")
    func expandingPartIsScoped() {
        let model = model()
        let aPart = tracker { model.isExpanded(rowID: "a", partID: "p") }
        let bPart = tracker { model.isExpanded(rowID: "b", partID: "p") }
        model.setExpanded(true, rowID: "a", partID: "p")
        #expect(aPart.fired)
        #expect(!bPart.fired)
    }
}
#endif
