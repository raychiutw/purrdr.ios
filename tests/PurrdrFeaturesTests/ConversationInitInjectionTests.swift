#if os(macOS)
import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 聊天 model 的依賴只經 initializer 給齊(#566):建立後沒有公開 setter,送出管線的步驟以具名欄位取得。
@MainActor
@Suite("聊天 model initializer 注入")
struct ConversationInitInjectionTests {
    private static func make(links: ConversationModel.HostLinks = .init(), stages: SendStages = SendStages()) -> ConversationModel {
        let host = FakeHostConnection()
        return ConversationModel(
            client: HerdrClient(connection: host), transcripts: TranscriptReader(connection: host),
            paneID: "w1:p1", knownSessionID: nil, cache: InMemoryConversationCache(),
            sendStages: stages, links: links)
    }

    @Test("initializer 給的回呼與來源建立後可用")
    func linksComeFromInitializer() async {
        var delivered = 0
        let model = Self.make(links: .init(onPromptDelivered: { delivered += 1 }, awayStart: { Date(timeIntervalSince1970: 5) }))
        #expect(model.awayStart?() == Date(timeIntervalSince1970: 5))
        model.onPromptDelivered?()
        #expect(delivered == 1)
        #expect(model.gitChanges == nil)
    }

    @Test("送出管線的步驟以具名欄位給,畫面直接拿到各步驟")
    func namedStages() {
        let check = SecretCheck()
        let countdown = UndoSendCountdown(seconds: { 3 })
        let model = Self.make(stages: SendStages(secretCheck: check, undo: countdown))
        #expect(model.secretCheck === check)
        #expect(model.undoSend === countdown)
        #expect(model.sendWhenDone == nil)
        #expect(model.offlineQueue == nil)
    }
}
#endif
