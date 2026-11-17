import Foundation
import PurrdrCore

/// 假的主機連線：對預期的 herdr 請求(以 method 比對)回放錄製的真實回應，並記錄 app 送出的請求。
/// 上層功能的測試用它，就不必知道連線方式。
///
/// ```swift
/// let connection = FakeHostConnection()
/// await connection.expect("session.snapshot", reply: Fixtures.data("session.snapshot.ndjson"))
/// let model = AgentListModel(client: HerdrClient(connection: connection))
/// ```
///
/// 沒有預期的請求一律以 `FakeHostConnectionError.unexpectedRequest` 失敗。
public actor FakeHostConnection: HostConnection {
    /// app 送出的 herdr 請求行(含 `events.subscribe`),依送出順序。
    public private(set) var requests: [String] = []
    /// 每條 Agent 事件串流是否已被 app 關閉，依開啟順序。
    public private(set) var subscriptionsClosed: [Bool] = []
    public private(set) var disconnectCount = 0

    private var expectations: [(method: String, reply: Data)] = []
    private var subscriptions: [AsyncThrowingStream<Data, any Error>.Continuation] = []

    public init() {}

    /// 預期 app 會送出 `method` 的請求，以 `reply`(錄製的回應)回應。同一 method 可預期多次，依序消耗。
    /// `events.subscribe` 的回應送完後串流保持開著，之後用 `send(event:toSubscription:)` 推事件。
    public func expect(_ method: String, reply: Data) {
        expectations.append((method, reply))
    }

    /// 還沒被送出的預期請求(method)。
    public var unmetExpectations: [String] { expectations.map(\.method) }

    public func herdrRequest(_ request: Data, deadline: Duration?) async throws -> Data {
        let reply = try consume(request)
        return reply.firstIndex(of: 0x0A).map { reply[reply.startIndex..<$0] } ?? reply
    }

    public func herdrEvents(_ request: Data) async throws -> AsyncThrowingStream<Data, any Error> {
        let reply = try consume(request)
        let (lines, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        for line in reply.split(separator: 0x0A) { continuation.yield(Data(line)) }
        let index = subscriptions.count
        subscriptions.append(continuation)
        subscriptionsClosed.append(false)
        continuation.onTermination = { _ in Task { await self.closeSubscription(index) } }
        return lines
    }

    /// 對第 `index` 條 Agent 事件串流(從 0 起算)送出一行事件。
    public func send(event: Data, toSubscription index: Int) {
        for line in event.split(separator: 0x0A) { subscriptions[index].yield(Data(line)) }
    }

    public func readTranscript(_ request: TranscriptRequest) async throws -> Data {
        throw FakeHostConnectionError.unsupported
    }

    public func openPaneTerminal(target: String, columns: Int, rows: Int, takeover: Bool) async throws -> PaneTerminalConnection {
        throw FakeHostConnectionError.unsupported
    }

    public func disconnect() async {
        disconnectCount += 1
    }

    private func consume(_ request: Data) throws -> Data {
        let method = (try? JSONSerialization.jsonObject(with: request) as? [String: Any])?["method"] as? String ?? ""
        requests.append(String(decoding: request, as: UTF8.self))
        guard let index = expectations.firstIndex(where: { $0.method == method }) else {
            throw FakeHostConnectionError.unexpectedRequest(method)
        }
        return expectations.remove(at: index).reply
    }

    private func closeSubscription(_ index: Int) {
        subscriptionsClosed[index] = true
    }
}

public enum FakeHostConnectionError: Error, Equatable {
    case unexpectedRequest(String)
    /// 這個假連線還沒有對話紀錄與 Pane 終端機。
    case unsupported
}
