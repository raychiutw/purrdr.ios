import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrTestSupport
import Testing

@testable import PurrdrFeatures

/// UI 測試替身的 Send When Done(#305):HTTPS 主機的連線要認得成主機端佇列,排入、重排與刪除照主機服務的規則。
@MainActor
@Suite("UI 測試替身:Send When Done")
struct UITestingSendWhenDoneTests {
    static func host() throws -> any SendWhenDoneHosting {
        let id = UUID()
        let access = HostServiceAccess.uiTesting(channel: FakeHost(), pairedHosts: [id])
        let configuration = HostConfiguration(id: id, name: "Studio", hostService: try #require(HostServiceAddress("studio.tail1234.ts.net")))
        let connection = access.connection(for: configuration, address: try #require(HostServiceAddress("studio.tail1234.ts.net")))
        return try #require(connection as? any SendWhenDoneHosting, "UI 測試的主機服務連線不是 SendWhenDoneHosting")
    }

    @Test("可用、排入、重排、刪除")
    func queueLifecycle() async throws {
        let host = try Self.host()
        #expect(await host.sendWhenDoneAvailability() == .available)

        let first = try await host.sendWhenDoneAdd(paneID: "w1:p1", text: "一", expectedSession: "s")
        let second = try await host.sendWhenDoneAdd(paneID: "w1:p1", text: "二", expectedSession: "s")
        try await host.sendWhenDoneReorder(paneID: "w1:p1", itemIDs: [second, first])
        #expect(try await host.sendWhenDoneQueues().first?.items.map(\.id) == [second, first])
        await #expect(throws: HostServiceError.queueItemUnknown) {
            try await host.sendWhenDoneReorder(paneID: "w1:p1", itemIDs: [first])
        }
        try await host.sendWhenDoneRemove(paneID: "w1:p1", itemID: first)
        #expect(try await host.sendWhenDoneQueues().first?.items.map(\.id) == [second])
    }

    @Test("HTTPS 主機的聊天拿得到佇列、開關可打開")
    func conversationOnHostServiceHostCanQueue() async throws {
        let address = try #require(HostServiceAddress("studio.tail1234.ts.net"))
        let configuration = HostConfiguration(id: UUID(), name: "Studio", hostService: address)
        let store = MemoryHostStore()
        store.hosts = [configuration]
        let model = HostsModel(
            store: store, demoChannel: FakeHost(), hostService: .uiTesting(channel: FakeHost(), pairedHosts: [configuration.id]),
            makeChannel: ChannelFactory().make)
        model.load()

        let chat = model.member(for: .host(configuration.id)).conversation(ChatRoute(host: .host(configuration.id), paneID: "w1:p1"), sessionID: nil)
        let queue = try #require(chat.sendWhenDone, "聊天沒有 Send When Done")
        let running = Task { await queue.run() }
        defer { running.cancel() }
        for _ in 0..<5_000 where queue.availability != .available { await Task.yield() }

        #expect(queue.availability == .available)
        queue.toggle()
        #expect(queue.isEnabled)
    }
}
