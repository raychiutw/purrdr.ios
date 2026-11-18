import Foundation
import PurrdrCore
import PurrdrSSH

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

    public func herdrRequest(_ request: Data, deadline: Duration) async throws -> Data {
        let method = Self.method(of: request)
        let reply = try consume(request)
        if let index = heldMethods.firstIndex(of: method) {
            heldMethods.remove(at: index)
            await withCheckedContinuation { held.append($0) }
        }
        return reply.firstIndex(of: 0x0A).map { reply[reply.startIndex..<$0] } ?? reply
    }

    private var heldMethods: [String] = []
    private var held: [CheckedContinuation<Void, Never>] = []

    /// 下一個 `method` 請求先不回應，等 `releaseHeld()`(模擬讀取進行中)。
    public func hold(_ method: String) {
        heldMethods.append(method)
    }

    /// 正被擋著、還沒回應的請求數。
    public var heldCount: Int { held.count }

    /// 回應所有被擋著的請求。
    public func releaseHeld() {
        let waiting = held
        held = []
        for continuation in waiting { continuation.resume() }
    }

    /// 主機那端結束第 `index` 條 Agent 事件串流(斷線)。
    public func finish(subscription index: Int) {
        subscriptions[index].finish()
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

    /// app 送出的對話紀錄讀取，依送出順序。
    public private(set) var transcriptRequests: [TranscriptRequest] = []
    private var transcriptAnswer: (@Sendable (TranscriptRequest) throws -> Data)?

    /// 之後的對話紀錄讀取以 `answer` 回應(格式同主機腳本的輸出)。沒設定時一律 `unsupported`。
    public func answerTranscripts(_ answer: @escaping @Sendable (TranscriptRequest) throws -> Data) {
        transcriptAnswer = answer
    }

    public func readTranscript(_ request: TranscriptRequest) async throws -> Data {
        transcriptRequests.append(request)
        guard let transcriptAnswer else { throw FakeHostConnectionError.unsupported }
        return try transcriptAnswer(request)
    }

    /// 開過的對話紀錄追蹤(路徑與游標),依開啟順序。追蹤像 HTTPS 一樣由這裡推送：用 `send(_:toFollow:)`。
    public private(set) var transcriptFollowOpenings: [TranscriptFollowOpening] = []
    /// 每個追蹤是否已結束(app 不再讀或主機結束),依開啟順序。
    public private(set) var transcriptFollowsClosed: [Bool] = []
    private var transcriptFollows: [AsyncThrowingStream<TranscriptFollowEvent, any Error>.Continuation] = []

    public func followTranscript(path: String, from cursor: Int, pace: TranscriptFollowPace) async -> AsyncThrowingStream<TranscriptFollowEvent, any Error> {
        let (events, continuation) = AsyncThrowingStream<TranscriptFollowEvent, any Error>.makeStream()
        let index = transcriptFollows.count
        transcriptFollowOpenings.append(TranscriptFollowOpening(path: path, cursor: cursor))
        transcriptFollows.append(continuation)
        transcriptFollowsClosed.append(false)
        continuation.onTermination = { _ in Task { await self.closeTranscriptFollow(index) } }
        return events
    }

    /// 對第 `index` 個追蹤(從 0 起算)推送一則事件;`.replaced` 之後追蹤結束(同主機連線的約定)。
    public func send(_ event: TranscriptFollowEvent, toFollow index: Int) {
        transcriptFollows[index].yield(event)
        if case .replaced = event { transcriptFollows[index].finish() }
    }

    private func closeTranscriptFollow(_ index: Int) {
        transcriptFollowsClosed[index] = true
    }

    /// 開過的 Pane 終端機，依開啟順序。
    public private(set) var paneTerminalOpenings: [PaneTerminalOpening] = []
    /// app 對 Pane 終端機送出的輸入(不含 release),依送出順序。
    public private(set) var paneTerminalInputs: [TerminalInput] = []
    private var paneTerminalExpectations: [(fixture: String, readOnly: Bool)] = []

    /// 下一次開 Pane 終端機時，回放 `session-control/<fixture>` 的 frame(不送 `terminal.closed`,保持開著);
    /// `readOnly` 是唯讀裝置(主機服務以 observe 接上)。release 時以 detached 結束。
    public func expectPaneTerminal(replaying fixture: String, readOnly: Bool = false) {
        paneTerminalExpectations.append((fixture, readOnly))
    }

    public func openPaneTerminal(target: String, columns: Int, rows: Int, takeover: Bool) async throws -> PaneTerminalConnection {
        paneTerminalOpenings.append(PaneTerminalOpening(target: target, columns: columns, rows: rows, takeover: takeover))
        guard !paneTerminalExpectations.isEmpty else { throw FakeHostConnectionError.unsupported }
        let expectation = paneTerminalExpectations.removeFirst()
        let (events, continuation) = AsyncStream<PaneTerminalEvent>.makeStream()
        for line in Fixtures.sessionControlLines(expectation.fixture) {
            guard let frame = Self.frame(line) else { continue }
            continuation.yield(.frame(frame))
        }
        let transport = FakePaneTerminalTransport(onSend: { input in await self.record(input) }, onRelease: {
            continuation.yield(.closed(.detached))
            continuation.finish()
        })
        return PaneTerminalConnection(events: events, transport: transport, isViewOnly: expectation.readOnly)
    }

    private func record(_ input: TerminalInput) {
        paneTerminalInputs.append(input)
    }

    private static func frame(_ line: Data) -> TerminalFrame? {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], object["type"] as? String == "terminal.frame",
              let seq = object["seq"] as? Int, let width = object["width"] as? Int, let height = object["height"] as? Int,
              let base64 = object["bytes"] as? String, let bytes = Data(base64Encoded: base64) else { return nil }
        return TerminalFrame(seq: UInt64(seq), columns: width, rows: height, full: object["full"] as? Bool ?? false, bytes: bytes)
    }

    public func disconnect() async {
        disconnectCount += 1
    }

    private static func method(of request: Data) -> String {
        (try? JSONSerialization.jsonObject(with: request) as? [String: Any])?["method"] as? String ?? ""
    }

    private func consume(_ request: Data) throws -> Data {
        let method = Self.method(of: request)
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
    /// 這個假連線還沒有對話紀錄;Pane 終端機沒有預期(`expectPaneTerminal`)。
    case unsupported
}

/// 一次開對話紀錄追蹤的參數。
public struct TranscriptFollowOpening: Sendable, Equatable {
    public var path: String
    public var cursor: Int

    public init(path: String, cursor: Int) {
        self.path = path
        self.cursor = cursor
    }
}

/// 一次開 Pane 終端機的參數。
public struct PaneTerminalOpening: Sendable, Equatable {
    public var target: String
    public var columns: Int
    public var rows: Int
    public var takeover: Bool

    public init(target: String, columns: Int, rows: Int, takeover: Bool) {
        self.target = target
        self.columns = columns
        self.rows = rows
        self.takeover = takeover
    }
}

private struct FakePaneTerminalTransport: PaneTerminalTransport {
    let onSend: @Sendable (TerminalInput) async -> Void
    let onRelease: @Sendable () -> Void

    func send(_ input: TerminalInput) async throws {
        await onSend(input)
    }

    func release() async {
        onRelease()
    }
}
