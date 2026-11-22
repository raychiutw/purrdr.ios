import Foundation
import PurrdrCore
import PurrdrHTTPS
import Testing

/// Send When Done(#305):`HTTPSHostConnection` 以主機服務的 `queue.*` 與推送 `queue.changed` 實作 `SendWhenDoneHosting`。
@Suite("HTTPS 主機 Send When Done")
struct HTTPSSendWhenDoneTests {
    static let listReply = #"{"type":"queue.list.result","queues":[{"pane_id":"w1:p1","items":[{"item_id":"q1","text":"跑一次全部測試","expected_session":"sess-1"},{"item_id":"q2","text":"再整理 commit","expected_session":"sess-1"}],"paused":"session_changed"},{"pane_id":"w2:p1","items":[]}]}"#

    private static func start(
        _ replies: [String: [String]] = [:], hostServiceVersion: String = "0.7.0", readOnly: Bool = false
    ) async throws -> FakeHostService {
        var settings = FakeHostService.Settings(deviceReplies: replies, hostServiceVersion: hostServiceVersion)
        if readOnly { settings.readOnlyTokens = ["token-ok"] }
        return try await FakeHostService.start(settings)
    }

    private static func connection(_ service: FakeHostService) -> HTTPSHostConnection {
        HTTPSHostConnection(address: service.address, deviceToken: { "token-ok" })
    }

    @Test("讀佇列：每個 pane 的訊息依序，暫停原因對應")
    func listsQueues() async throws {
        let service = try await Self.start(["queue.list": [Self.listReply]])
        defer { Task { await service.stop() } }

        let queues = try await Self.connection(service).sendWhenDoneQueues()

        #expect(queues == [
            SendWhenDoneQueue(
                paneID: "w1:p1",
                items: [
                    SendWhenDoneItem(id: "q1", text: "跑一次全部測試", expectedSession: "sess-1"),
                    SendWhenDoneItem(id: "q2", text: "再整理 commit", expectedSession: "sess-1"),
                ], pause: .sessionChanged),
            SendWhenDoneQueue(paneID: "w2:p1", items: []),
        ])
    }

    @Test("排入送出 queue.add 帶 pane、文字與 expected_session,回傳 item_id")
    func addSendsFields() async throws {
        let service = try await Self.start(["queue.add": [#"{"type":"queue.add.result","item_id":"q9"}"#]])
        defer { Task { await service.stop() } }

        let id = try await Self.connection(service).sendWhenDoneAdd(paneID: "w1:p1", text: "接著寫文件", expectedSession: "sess-1")

        #expect(id == "q9")
        let sent = try #require(service.messages(ofType: "queue.add").first)
        #expect(sent["pane_id"] as? String == "w1:p1")
        #expect(sent["text"] as? String == "接著寫文件")
        #expect(sent["expected_session"] as? String == "sess-1")
    }

    @Test("佇列滿了：queueFull")
    func fullQueueThrowsQueueFull() async throws {
        let service = try await Self.start(["queue.add": [#"{"type":"error","code":"queue_full","message":"20 items"}"#]])
        defer { Task { await service.stop() } }

        await #expect(throws: HostServiceError.queueFull) {
            try await Self.connection(service).sendWhenDoneAdd(paneID: "w1:p1", text: "x", expectedSession: "s")
        }
    }

    @Test("刪除送出 queue.remove;已不在佇列：queueItemUnknown")
    func removeSendsItemAndMapsUnknown() async throws {
        let service = try await Self.start([
            "queue.remove": [
                #"{"type":"queue.remove.result"}"#,
                #"{"type":"error","code":"queue_item_unknown","message":"gone"}"#,
            ],
        ])
        defer { Task { await service.stop() } }
        let connection = Self.connection(service)

        try await connection.sendWhenDoneRemove(paneID: "w1:p1", itemID: "q1")
        let sent = try #require(service.messages(ofType: "queue.remove").first)
        #expect(sent["pane_id"] as? String == "w1:p1")
        #expect(sent["item_id"] as? String == "q1")

        await #expect(throws: HostServiceError.queueItemUnknown) {
            try await connection.sendWhenDoneRemove(paneID: "w1:p1", itemID: "q1")
        }
    }

    @Test("重排送出 queue.reorder 與新的順序")
    func reorderSendsItemIDs() async throws {
        let service = try await Self.start(["queue.reorder": [#"{"type":"queue.reorder.result"}"#]])
        defer { Task { await service.stop() } }

        try await Self.connection(service).sendWhenDoneReorder(paneID: "w1:p1", itemIDs: ["q2", "q1"])

        let sent = try #require(service.messages(ofType: "queue.reorder").first)
        #expect(sent["item_ids"] as? [String] == ["q2", "q1"])
    }

    @Test("主機推 queue.changed:變動串流收到佇列與已送出的訊息")
    func changesStreamDeliversPushes() async throws {
        let service = try await Self.start()
        defer { Task { await service.stop() } }
        let connection = Self.connection(service)

        let changes = try await connection.sendWhenDoneChanges()
        var iterator = changes.makeAsyncIterator()
        try await service.push(
            #"{"type":"queue.changed","queue":{"pane_id":"w1:p1","items":[{"item_id":"q2","text":"再整理 commit","expected_session":"sess-1"}]},"sent_item_id":"q1"}"#)

        let change = try #require(try await iterator.next())
        #expect(change.sentItemID == "q1")
        #expect(change.queue == SendWhenDoneQueue(
            paneID: "w1:p1", items: [SendWhenDoneItem(id: "q2", text: "再整理 commit", expectedSession: "sess-1")]))
    }

    @Test("連線結束：變動串流以連線錯誤結束")
    func changesStreamEndsWhenConnectionDrops() async throws {
        let service = try await Self.start()
        defer { Task { await service.stop() } }
        let connection = Self.connection(service)

        let changes = try await connection.sendWhenDoneChanges()
        await connection.disconnect()

        var thrown: (any Error)?
        do { for try await _ in changes {} } catch { thrown = error }
        #expect(thrown as? HostServiceError == .connectionLost)
    }

    @Test("主機服務 0.6.0 太舊：要更新主機服務,不送出")
    func oldHostServiceRequiresUpdate() async throws {
        let service = try await Self.start(hostServiceVersion: "0.6.0")
        defer { Task { await service.stop() } }
        let connection = Self.connection(service)

        #expect(await connection.sendWhenDoneAvailability() == .needsHostService)
        await #expect(throws: HostServiceError.hostServiceUpdateRequired(.agentObserver, installedVersion: "0.6.0")) {
            try await connection.sendWhenDoneAdd(paneID: "w1:p1", text: "x", expectedSession: "s")
        }
        #expect(service.messages(ofType: "queue.add").isEmpty)
    }

    @Test("可用性:0.7.0 可寫入的裝置可用;唯讀裝置停用")
    func availability() async throws {
        let writable = try await Self.start()
        defer { Task { await writable.stop() } }
        #expect(await Self.connection(writable).sendWhenDoneAvailability() == .available)

        let readOnly = try await Self.start(readOnly: true)
        defer { Task { await readOnly.stop() } }
        #expect(await Self.connection(readOnly).sendWhenDoneAvailability() == .readOnlyDevice)
    }
}
