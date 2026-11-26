import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 聊天的 context 取自 Claude Code 的 status line(每個 session 一份),沒有時退回對話紀錄算法(#388)。
@MainActor
@Suite("session 狀態(context 來源)")
struct ConversationSessionStatusTests {
    /// 記錄被問的 session、依 session id 回各自的狀態。
    final class Reader: ClaudeSessionStatusReading, @unchecked Sendable {
        private let lock = NSLock()
        private var _asked: [[String]] = []
        var statuses: [String: ClaudeSessionStatus]
        var error: (any Error)?
        init(_ statuses: [String: ClaudeSessionStatus] = [:]) { self.statuses = statuses }
        var asked: [[String]] { lock.withLock { _asked } }
        func sessionStatuses(sessionIDs: [String]) async throws -> [String: ClaudeSessionStatus] {
            lock.withLock { _asked.append(sessionIDs) }
            if let error { throw error }
            return statuses.filter { sessionIDs.contains($0.key) }
        }
    }

    static let session = ConversationModelTests.sessionID

    static func opened(reader: Reader?) async throws -> ConversationAnswerTests.Setup {
        let setup = try await ConversationPermissionModeTests.opened(links: .init(sessionStatusReader: reader))
        return setup
    }

    @Test("status line 有這個 session 的 context:以它為準,別的 session 的不混進來")
    func usesOwnSessionStatus() async throws {
        let reader = Reader([
            Self.session: ClaudeSessionStatus(sessionID: Self.session, contextPercent: 31.4, contextWindowSize: 1_000_000),
            "other-session": ClaudeSessionStatus(sessionID: "other-session", contextPercent: 90),
        ])
        let setup = try await Self.opened(reader: reader)

        await setup.model.refreshSessionStatusIfDue()

        #expect(setup.model.header.progress.contextPercent == 31)
        #expect(reader.asked == [[Self.session]])
    }

    @Test("沒有 session 檔:退回對話紀錄算法,畫面不空白")
    func fallsBackWithoutStatus() async throws {
        let setup = try await Self.opened(reader: Reader())
        let fallback = setup.model.progress.contextPercent

        await setup.model.refreshSessionStatusIfDue()

        #expect(setup.model.sessionStatus == nil)
        #expect(setup.model.header.progress.contextPercent == fallback)
    }

    @Test("讀取失敗(未安裝、舊版主機服務):清掉之前的值,退回算法")
    func fallsBackOnError() async throws {
        let reader = Reader([Self.session: ClaudeSessionStatus(sessionID: Self.session, contextPercent: 50)])
        let setup = try await Self.opened(reader: reader)
        await setup.model.refreshSessionStatusIfDue()
        #expect(setup.model.header.progress.contextPercent == 50)

        reader.error = HostServiceError.unexpectedResponse
        setup.clock.advance(by: ConversationModel.sessionStatusInterval + 1)
        await setup.model.refreshSessionStatusIfDue()

        #expect(setup.model.sessionStatus == nil)
        #expect(setup.model.header.progress.contextPercent == setup.model.progress.contextPercent)
    }

    @Test("沒有帶 context 的檔(used_percentage 為 null):不蓋掉退回算法的值")
    func nullPercentKeepsFallback() async throws {
        let reader = Reader([Self.session: ClaudeSessionStatus(sessionID: Self.session, contextPercent: nil, model: "claude-opus-5-5")])
        let setup = try await Self.opened(reader: reader)

        await setup.model.refreshSessionStatusIfDue()

        #expect(setup.model.header.progress.contextPercent == setup.model.progress.contextPercent)
    }

    @Test("兩次讀取至少隔 10 秒,不是每 2 秒輪詢都問主機")
    func throttlesReads() async throws {
        let reader = Reader([Self.session: ClaudeSessionStatus(sessionID: Self.session, contextPercent: 10)])
        let setup = try await Self.opened(reader: reader)

        await setup.model.refreshSessionStatusIfDue()
        setup.clock.advance(by: 2)
        await setup.model.refreshSessionStatusIfDue()
        #expect(reader.asked.count == 1)

        reader.statuses[Self.session]?.contextPercent = 20
        setup.clock.advance(by: ConversationModel.sessionStatusInterval)
        await setup.model.refreshSessionStatusIfDue()
        #expect(reader.asked.count == 2)
        #expect(setup.model.header.progress.contextPercent == 20)
    }

    @Test("沒有讀取來源(例如 UI 測試替身):只用退回算法")
    func noReader() async throws {
        let setup = try await Self.opened(reader: nil)

        await setup.model.refreshSessionStatusIfDue()

        #expect(setup.model.sessionStatus == nil)
        #expect(setup.model.header.progress == setup.model.progress)
    }

    // MARK: 用量環的載入狀態(#644)

    /// 讀取卡在半途直到放行,給「讀取中」的斷言。
    final class GatedReader: ClaudeSessionStatusReading, @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: CheckedContinuation<Void, Never>?
        private var released = false
        var statuses: [String: ClaudeSessionStatus] = [:]
        func sessionStatuses(sessionIDs: [String]) async throws -> [String: ClaudeSessionStatus] {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    if released { continuation.resume() } else { waiting = continuation }
                }
            }
            return statuses
        }
        func release() {
            lock.withLock {
                released = true
                waiting?.resume()
                waiting = nil
            }
        }
    }

    @Test("還沒讀過第一次結果:載入中;讀到之後不再載入")
    func loadingUntilFirstResult() async throws {
        let reader = Reader([Self.session: ClaudeSessionStatus(sessionID: Self.session, contextPercent: 31)])
        let setup = try await Self.opened(reader: reader)
        #expect(setup.model.isSessionStatusLoading)

        await setup.model.refreshSessionStatusIfDue()

        #expect(!setup.model.isSessionStatusLoading)
        #expect(setup.model.sessionStatus != nil)
    }

    @Test("讀取進行中仍是載入中,結果回來才結束")
    func loadingWhileReadInFlight() async throws {
        let reader = GatedReader()
        reader.statuses = [Self.session: ClaudeSessionStatus(sessionID: Self.session, contextPercent: 12)]
        let setup = try await ConversationPermissionModeTests.opened(links: .init(sessionStatusReader: reader))
        let model = setup.model

        let reading = Task { await model.refreshSessionStatusIfDue() }
        for _ in 0..<50 { await Task.yield() }
        #expect(model.isSessionStatusLoading)

        reader.release()
        await reading.value
        #expect(!model.isSessionStatusLoading)
    }

    @Test("沒有這個 session 的檔(無資料):結束載入")
    func noDataEndsLoading() async throws {
        let setup = try await Self.opened(reader: Reader())
        await setup.model.refreshSessionStatusIfDue()
        #expect(!setup.model.isSessionStatusLoading)
        #expect(setup.model.sessionStatus == nil)
    }

    @Test("讀取錯誤:結束載入(畫面換成空環)")
    func errorEndsLoading() async throws {
        let reader = Reader()
        reader.error = HostServiceError.unexpectedResponse
        let setup = try await Self.opened(reader: reader)
        await setup.model.refreshSessionStatusIfDue()
        #expect(!setup.model.isSessionStatusLoading)
    }

    @Test("沒有讀取來源:不會一直轉圈")
    func noReaderEndsLoading() async throws {
        let setup = try await Self.opened(reader: nil)
        await setup.model.refreshSessionStatusIfDue()
        #expect(!setup.model.isSessionStatusLoading)
    }
}
