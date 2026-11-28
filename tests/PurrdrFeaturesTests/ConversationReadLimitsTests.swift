import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrTestSupport
import Testing

/// #656 點進聊天的讀取量依網路類型:開啟讀 300 行、bytes 上限看網路(每次讀取當下判斷)、視窗沒有可讀訊息時最多補讀 1 頁,
/// 補讀與往上翻的每一頁帶同樣的 bytes 上限。
@MainActor
@Suite("對話開啟:讀取限額")
struct ConversationReadLimitsTests {
    typealias R = ConversationReadableMessageTests
    typealias W = ConversationWorkingOpenTests

    static func model(
        _ connection: FakeHostConnection, network: @escaping @MainActor () -> TrafficNetwork?
    ) -> ConversationModel {
        ConversationModel(
            client: HerdrClient(connection: connection), transcripts: TranscriptReader(connection: connection), paneID: W.paneID,
            knownSessionID: W.sessionID, cache: InMemoryConversationCache(), clock: TestClock().clock,
            links: ConversationModel.HostLinks(readLimits: { TranscriptReadLimits.limits(for: network()) }))
    }

    static func toolOnly() -> [String] { (0..<1_500).flatMap { W.toolPair($0) } }

    @Test("開啟:Wi-Fi 讀 300 行、512 KiB;行動網路 300 行、256 KiB")
    func openUsesNetworkLimits() async throws {
        for (network, bytes) in [(TrafficNetwork.wifi, 524_288), (.cellular, 262_144)] {
            let connection = FakeHostConnection()
            await connection.expect(.snapshot, wire: Fixtures.data("session.snapshot.ndjson"))
            await R.answering(connection, lines: Array(R.fixture[0..<28]))
            let chat = try await R.open(Self.model(connection, network: { network }), connection)
            defer { chat.cancel() }

            let first = try #require(await connection.transcriptWindowReads.first)
            #expect(first.lines == 300)
            #expect(first.maxBytes == bytes, "\(network)")
        }
    }

    @Test("網路在每次讀取當下判斷:開啟前換網路就用新的上限")
    func networkIsReadAtOpenTime() async throws {
        let connection = FakeHostConnection()
        await connection.expect(.snapshot, wire: Fixtures.data("session.snapshot.ndjson"))
        await R.answering(connection, lines: Array(R.fixture[0..<28]))
        final class Box: @unchecked Sendable { var network = TrafficNetwork.wifi }
        let box = Box()
        let model = Self.model(connection, network: { box.network })
        box.network = .cellular
        let chat = try await R.open(model, connection)
        defer { chat.cancel() }

        #expect(await connection.transcriptWindowReads.first?.maxBytes == 262_144)
    }

    @Test("視窗沒有可讀訊息:自動補讀最多 1 頁,補讀帶同樣的 bytes 上限(最壞往返 2 次)")
    func backfillIsOnePage() async throws {
        let connection = FakeHostConnection()
        await connection.expect(.snapshot, wire: Fixtures.data("session.snapshot.ndjson"))
        await R.answering(connection, lines: Self.toolOnly())
        let chat = try await R.open(Self.model(connection, network: { .cellular }), connection)
        defer { chat.cancel() }

        let reads = await connection.transcriptWindowReads
        #expect(reads.count == 2, "實際 \(reads.map { "\($0.lines)/\($0.maxBytes)" })")
        #expect(reads.last?.maxBytes == 262_144)
    }

    @Test("往上翻的每一頁帶同樣的 bytes 上限")
    func scrollbackPageCarriesLimit() async throws {
        let connection = FakeHostConnection()
        await connection.expect(.snapshot, wire: Fixtures.data("session.snapshot.ndjson"))
        await R.answering(connection, lines: W.lines)
        let model = Self.model(connection, network: { .wifi })
        let chat = try await R.open(model, connection)
        defer { chat.cancel() }

        let before = await connection.transcriptWindowReads.count
        await model.loadOlder()
        let reads = await connection.transcriptWindowReads
        if reads.count > before { #expect(reads.last?.maxBytes == 524_288) }
        #expect(reads.dropFirst().allSatisfy { $0.maxBytes == 524_288 }, "實際 \(reads.map(\.maxBytes))")
    }
}
