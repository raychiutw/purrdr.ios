#if os(macOS)
import Foundation
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 今日推播用量(#677):進頁面讀一次、讀不到不顯示;時區換算;到達上限的文字。
@MainActor
@Suite("今日推播用量")
struct PushUsageModelTests {
    static let utcMidnight = Date(timeIntervalSince1970: 1_795_824_000)  // 2026-11-28T00:00:00Z
    static let taipei = TimeZone(identifier: "Asia/Taipei")!
    static let english = Locale(identifier: "en_US")

    let backend = HTTPStub()
    let tokens = InMemoryTokenStore()

    init() throws {
        try tokens.setRefreshToken("refresh-1")
        backend.on("POST", "/v1/sessions/refresh", .json(200, Replies.session(refreshToken: "refresh-2", member: SubscriptionReplies.member)))
    }

    func model() -> PushUsageModel {
        let service = PushService(
            session: MemberSession(transport: URLSessionBackendTransport(baseURL: backend.baseURL, session: backend.urlSession), tokenStore: tokens),
            platform: FakePushPlatform(), store: InMemoryPushPairingStore(),
            device: PushDeviceIdentity(id: PushDeviceID(rawValue: "6f1c2a4e-3b7d-4c8e-9a10-2b3c4d5e6f70")!, name: "iPhone", model: .iPhone),
            configuration: PushConfiguration(
                endpoint: URL(string: "https://backend.test/v1/push")!, environment: .production, pluginSource: "raychiutw/purrdr.host/host-plugin"),
            isSignedIn: { true })
        return PushUsageModel(service: service)
    }

    @Test("讀到用量後顯示已送與上限")
    func loadsUsage() async throws {
        backend.on("GET", "/v1/members/me/push-usage", .json(200, #"{"usage":{"limit":100,"sent":23,"resetsAt":"2026-11-28T00:00:00.000Z"}}"#))
        let model = model()
        await model.load()
        let usage = try #require(model.usage)
        #expect(usage.sent == 23)
        #expect(PushUsageText(usage, timeZone: Self.taipei, locale: Self.english).summary == "Today 23 of 100")
    }

    @Test("讀不到時不顯示(沒有用量),也不丟錯")
    func failureShowsNothing() async {
        backend.on("GET", "/v1/members/me/push-usage", .json(500, #"{"error":{"code":"server_error","message":"x"}}"#))
        let model = model()
        await model.load()
        #expect(model.usage == nil)
    }

    @Test("UTC 0:00 在台灣顯示 8:00")
    func resetTimeInTaipei() {
        let usage = PushDailyUsage(limit: 100, sent: 1, resetsAt: Self.utcMidnight)
        #expect(PushUsageText(usage, timeZone: Self.taipei, locale: Self.english).resetTime.hasPrefix("8:00"))
        #expect(PushUsageText(usage, timeZone: TimeZone(identifier: "UTC")!, locale: Self.english).resetTime.hasPrefix("12:00"))
    }

    @Test("到達上限顯示「今日已達上限」")
    func limitReachedSummary() {
        let text = PushUsageText(PushDailyUsage(limit: 100, sent: 100, resetsAt: Self.utcMidnight), timeZone: Self.taipei, locale: Self.english)
        #expect(text.summary == "Today’s limit reached")
    }
}
#endif
