import Foundation
import PurrdrCore

/// 假的主機端 Send When Done 佇列(#305):記憶體裡的佇列，`push(_:)` 模擬主機推 `queue.changed`。
public actor FakeSendWhenDoneHost: SendWhenDoneHosting {
    public enum Call: Equatable, Sendable {
        case queues
        case add(paneID: String, text: String, expectedSession: String)
        case remove(paneID: String, itemID: String)
        case reorder(paneID: String, itemIDs: [String])
    }

    public private(set) var calls: [Call] = []
    public private(set) var changeStreamsOpened = 0
    public var availability: SendWhenDoneAvailability
    /// 下一次操作丟這個錯誤(用掉就清掉)。
    public var failure: (any Error)?
    private var queues: [String: SendWhenDoneQueue]
    private var observers: [AsyncThrowingStream<SendWhenDoneChange, any Error>.Continuation] = []
    private var nextItem = 0

    public init(availability: SendWhenDoneAvailability = .available, queues: [SendWhenDoneQueue] = []) {
        self.availability = availability
        self.queues = Dictionary(uniqueKeysWithValues: queues.map { ($0.paneID, $0) })
    }

    public func setFailure(_ error: (any Error)?) { failure = error }

    public func sendWhenDoneAvailability() async -> SendWhenDoneAvailability { availability }

    public func sendWhenDoneQueues() async throws -> [SendWhenDoneQueue] {
        calls.append(.queues)
        try throwFailure()
        return Array(queues.values)
    }

    public func sendWhenDoneAdd(paneID: String, text: String, expectedSession: String) async throws -> String {
        calls.append(.add(paneID: paneID, text: text, expectedSession: expectedSession))
        try throwFailure()
        nextItem += 1
        let item = SendWhenDoneItem(id: "q\(nextItem)", text: text, expectedSession: expectedSession)
        var queue = queues[paneID] ?? SendWhenDoneQueue(paneID: paneID, items: [])
        queue.items.append(item)
        queues[paneID] = queue
        broadcast(SendWhenDoneChange(queue: queue))
        return item.id
    }

    public func sendWhenDoneRemove(paneID: String, itemID: String) async throws {
        calls.append(.remove(paneID: paneID, itemID: itemID))
        try throwFailure()
        guard var queue = queues[paneID], queue.items.contains(where: { $0.id == itemID }) else {
            throw HostServiceError.queueItemUnknown
        }
        queue.items.removeAll { $0.id == itemID }
        queues[paneID] = queue
        broadcast(SendWhenDoneChange(queue: queue))
    }

    public func sendWhenDoneReorder(paneID: String, itemIDs: [String]) async throws {
        calls.append(.reorder(paneID: paneID, itemIDs: itemIDs))
        try throwFailure()
    }

    public func sendWhenDoneChanges() async throws -> AsyncThrowingStream<SendWhenDoneChange, any Error> {
        changeStreamsOpened += 1
        let (stream, continuation) = AsyncThrowingStream<SendWhenDoneChange, any Error>.makeStream()
        observers.append(continuation)
        return stream
    }

    /// 主機推一個佇列變動(例如 Agent 做完、第一則送出)。
    public func push(_ change: SendWhenDoneChange) {
        queues[change.queue.paneID] = change.queue
        broadcast(change)
    }

    /// 連線斷了:所有變動串流以連線錯誤結束。
    public func dropConnection() {
        for observer in observers { observer.finish(throwing: HostServiceError.connectionLost) }
        observers = []
    }

    private func broadcast(_ change: SendWhenDoneChange) {
        for observer in observers { observer.yield(change) }
    }

    private func throwFailure() throws {
        guard let error = failure else { return }
        failure = nil
        throw error
    }
}
