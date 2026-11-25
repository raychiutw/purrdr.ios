#if os(macOS)
import Foundation
import Observation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrSSH
import PurrdrTestSupport
import Testing
@testable import PurrdrFeatures

/// 對話畫面的觀察範圍(#584):列表內容的計算只依賴列表需要的狀態,
/// 頂列標題、橫幅這類狀態摘要變化時不重算整份列表內容(長對話下是 O(n))。
@MainActor
@Suite("對話畫面觀察範圍")
struct ConversationObservationScopeTests {
    /// 唯讀旗標可中途改變的連線(模擬「這支裝置被配對成唯讀」只影響橫幅)。
    final class ReadOnlyFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isOn: Bool {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    struct FlagConnection: ForwardingHostConnection {
        let base: any HostConnection
        let flag: ReadOnlyFlag
        func isReadOnlyDevice() async throws -> Bool { flag.isOn }
    }

    /// 追蹤 `read` 讀到的 observable 屬性;之後有沒有被改動過。
    final class Tracker: @unchecked Sendable {
        private let flag = ReadOnlyFlag()
        var fired: Bool { flag.isOn }
        func track<T>(_ read: () -> T) {
            let flag = flag
            withObservationTracking { _ = read() } onChange: { flag.isOn = true }
        }
    }

    private func loadedModel() async throws -> (ConversationModel, ReadOnlyFlag, RoutingHost) {
        let shell = try LocalShellHost.temporary()
        try shell.write(ConversationModelTests.fixture, to: ConversationModelTests.transcriptPath)
        let host = RoutingHost(shell: shell)
        let flag = ReadOnlyFlag()
        let connection = FlagConnection(base: SSHHostConnection(channel: host), flag: flag)
        let model = ConversationModel(
            client: HerdrClient(connection: connection), transcripts: TranscriptReader(channel: host),
            paneID: ConversationModelTests.paneID, knownSessionID: ConversationModelTests.sessionID,
            cache: InMemoryConversationCache(), clock: TestClock().clock)
        await host.bridge.expect(HerdrCommand.bridge(), reply: ConversationModelTests.snapshot { $0["agent_status"] = "idle" })
        await model.poll()
        return (model, flag, host)
    }

    @Test("唯讀橫幅出現:標題與橫幅重讀,列表內容不重算")
    func readOnlyBannerDoesNotInvalidateList() async throws {
        let (model, flag, host) = try await loadedModel()
        let list = Tracker(), banner = Tracker()
        list.track { ConversationListContentBuilder.make(model) }
        banner.track { model.statusSummary.banner }

        flag.isOn = true
        await host.bridge.expect(HerdrCommand.bridge(), reply: ConversationModelTests.snapshot { $0["agent_status"] = "idle" })
        await model.poll()

        #expect(model.isReadOnly)
        #expect(banner.fired)
        #expect(!list.fired)
    }
}
#endif
