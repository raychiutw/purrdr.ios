import Foundation
import PurrdrCore
import Testing

/// 今日推播用量的 wire(#677,raychiutw/purrdr.server#36):GET `/v1/members/me/push-usage`。
@Suite("今日推播用量：wire")
struct MemberSessionPushUsageTests {
    typealias FakeBackend = MemberSessionPushDevicesTests.FakeBackend

    func makeSession(_ backend: FakeBackend) throws -> MemberSession {
        let tokens = InMemoryTokenStore()
        try tokens.setRefreshToken("refresh-1")
        return MemberSession(transport: backend, tokenStore: tokens)
    }

    @Test("解析今日上限、已送則數與下次歸零時間(UTC)")
    func decodesUsage() async throws {
        let backend = FakeBackend(["GET /v1/members/me/push-usage": MemberSessionPushDevicesTests.json(
            200, #"{"usage":{"limit":100,"sent":23,"resetsAt":"2026-11-28T00:00:00.000Z"}}"#)])
        let usage = try await makeSession(backend).pushUsage()

        #expect(usage.limit == 100)
        #expect(usage.sent == 23)
        #expect(usage.resetsAt == Date(timeIntervalSince1970: 1_795_824_000))
        #expect(!usage.isLimitReached)
    }

    @Test("已送達上限就是到達上限;超過也算")
    func limitReached() {
        let reset = Date(timeIntervalSince1970: 0)
        #expect(PushDailyUsage(limit: 100, sent: 100, resetsAt: reset).isLimitReached)
        #expect(PushDailyUsage(limit: 100, sent: 101, resetsAt: reset).isLimitReached)
        #expect(!PushDailyUsage(limit: 100, sent: 99, resetsAt: reset).isLimitReached)
    }

    @Test("回應格式不對丟 invalidResponse")
    func malformed() async throws {
        let backend = FakeBackend(["GET /v1/members/me/push-usage": MemberSessionPushDevicesTests.json(200, #"{"usage":{"limit":100}}"#)])
        await #expect(throws: BackendError.invalidResponse) { try await makeSession(backend).pushUsage() }
    }
}
