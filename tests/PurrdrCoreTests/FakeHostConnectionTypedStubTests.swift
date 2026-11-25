import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 假的主機連線(ADR-0015、#596 第一批):每個型別化操作都能直接 stub 回型別化的值或失敗,
/// 呼叫記進 `typedCalls` 與 `requests`,不經 herdr 位元組。上層測試改用它(第二批)。
@Suite("假主機連線的型別化 stub")
struct FakeHostConnectionTypedStubTests {
    static let snapshot = HostSnapshot(version: "0.9.5", agents: [])

    @Test("同一操作的 stub 依序消耗,呼叫與請求行都被記錄")
    func stubsConsumedInOrder() async throws {
        let connection = FakeHostConnection()
        await connection.stub(.snapshot, HostSnapshot(version: "first", agents: []))
        await connection.stub(.snapshot, HostSnapshot(version: "second", agents: []))

        #expect(try await connection.readSnapshot().version == "first")
        #expect(try await connection.readSnapshot().version == "second")
        #expect(await connection.typedCalls == ["readSnapshot", "readSnapshot"])
        #expect(await connection.requests.count == 2)
        #expect(await connection.unmetExpectations.isEmpty)
    }

    @Test("沒用到的 stub 列在 unmetExpectations")
    func unmetStubsAreListed() async {
        let connection = FakeHostConnection()
        await connection.stub(.sendKeys)
        await connection.stub(.paneRead, "screen")
        await connection.expectSubscription()

        #expect(Set(await connection.unmetExpectations) == ["events.subscribe", "pane.read", "pane.send_keys"])
    }

    @Test("送出類操作:成功、失敗與比對欄位都進請求行")
    func sendOperations() async throws {
        let connection = FakeHostConnection()
        await connection.stub(.sendKeys)
        await connection.stub(.sendText, failure: HostServiceError.paneChanged)

        try await connection.sendKeys(paneID: "w1:p1", keys: ["down", "enter"], expecting: SendExpectation(session: "s1"))
        await #expect(throws: HostServiceError.paneChanged) {
            try await connection.sendText(paneID: "w1:p1", text: "hi", expecting: .none)
        }

        let requests = await connection.requests
        #expect(requests.count == 2)
        #expect(requests[0].contains(#""method":"pane.send_keys""#))
        #expect(requests[0].contains(#""expected_session":"s1""#))
        #expect(requests[0].contains(#""pane_id":"w1:p1""#))
        #expect(!requests[1].contains("expected_session"))
        #expect(await connection.typedCalls == ["sendKeys w1:p1 down,enter", "sendText w1:p1 hi"])
    }

    @Test("stub 的值型別和操作不符時明確失敗,不是靜默略過")
    func typeMismatchFails() async {
        let connection = FakeHostConnection()
        await connection.stub(.paneRead, 42)

        await #expect(throws: FakeHostConnectionError.stubTypeMismatch("pane.read")) {
            _ = try await connection.readPaneScreen(paneID: "w1:p1", lines: 40, format: .text)
        }
    }

    @Test("hold 也擋型別化 stub,releaseHeld 放行")
    func holdBlocksStubbedOperation() async throws {
        let connection = FakeHostConnection()
        await connection.stub(.paneRead, "screen")
        await connection.hold("pane.read")

        let read = Task { try await connection.readPaneScreen(paneID: "w1:p1", lines: 40, format: .text) }
        while await connection.heldCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
        await connection.releaseHeld()

        #expect(try await read.value == "screen")
    }

    @Test("型別化事件訂閱:先給 started,之後推事件、以錯誤結束,訂閱內容被記錄")
    func typedSubscription() async throws {
        let connection = FakeHostConnection()
        await connection.expectSubscription()

        let events = try await connection.subscribeToEvents([EventSubscription(.workspaceUpdated)])
        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .subscriptionStarted)

        await connection.send(.event(name: "workspace_updated", paneID: nil), toSubscription: 0)
        #expect(try await iterator.next() == .event(name: "workspace_updated", paneID: nil))

        await connection.finish(subscription: 0, throwing: HerdrError.herdr(code: "events_lost", message: "lost"))
        await #expect(throws: HerdrError.herdr(code: "events_lost", message: "lost")) { _ = try await iterator.next() }

        #expect(await connection.subscribeRequests.count == 1)
        #expect(await connection.requests.first?.contains(#""method":"events.subscribe""#) == true)
    }

    @Test("事件訂閱可預期直接失敗")
    func subscriptionFailure() async {
        let connection = FakeHostConnection()
        await connection.expectSubscription(failure: HerdrError.herdr(code: "pane_not_found", message: "x"))

        await #expect(throws: HerdrError.herdr(code: "pane_not_found", message: "x")) {
            _ = try await connection.subscribeToEvents([EventSubscription(.workspaceUpdated)])
        }
    }
}
