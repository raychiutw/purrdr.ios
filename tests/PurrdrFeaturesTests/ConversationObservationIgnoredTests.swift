#if os(macOS)
import Foundation
import Observation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrSSH
import PurrdrTestSupport
import Testing
@testable import PurrdrFeatures

/// 聊天 model 沒有畫面讀的內部欄位標 `@ObservationIgnored`(#593):寫入不通知觀察者、不多算一次;
/// 畫面讀的欄位照常通知。
@MainActor
@Suite("聊天 model 的觀察範圍(內部欄位)")
struct ConversationObservationIgnoredTests {
    final class Fired: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isOn: Bool {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    private func makeModel() -> ConversationModel {
        let host = FakeHost()
        return ConversationModel(
            client: HerdrClient(channel: host), transcripts: TranscriptReader(channel: host),
            paneID: ConversationModelTests.paneID, knownSessionID: ConversationModelTests.sessionID,
            cache: InMemoryConversationCache(), clock: TestClock().clock)
    }

    private let message = TranscriptMessage(id: "m1", role: .user, date: nil, parts: [.text("hi")])

    @Test("內部欄位(沒有畫面讀):寫入不通知觀察者")
    func internalStateWritesDoNotNotify() {
        let model = makeModel()
        let fired = Fired()
        withObservationTracking { model.readObservationIgnoredStateForTesting() } onChange: { fired.isOn = true }

        model.writeObservationIgnoredStateForTesting(message: message, now: Date())

        #expect(!fired.isOn)
    }

    @Test("畫面讀的欄位(phase、isSending 等)寫入仍然通知")
    func screenReadStateStillNotifies() {
        let model = makeModel()
        let fired = Fired()
        withObservationTracking { _ = model.draft } onChange: { fired.isOn = true }

        model.draft = "新的草稿"

        #expect(fired.isOn)
    }
}
#endif
