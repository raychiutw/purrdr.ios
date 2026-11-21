import Foundation
import PurrdrCore

/// Send When Done(#305):主機服務的 `queue.list`／`queue.add`／`queue.remove`／`queue.reorder` 與推送 `queue.changed`。
extension HTTPSHostConnection: SendWhenDoneHosting {
    public func sendWhenDoneAvailability() async -> SendWhenDoneAvailability {
        guard let info = try? await hostServiceInfo(),
              HostServiceFeature.agentObserver.isAvailable(onHostServiceVersion: info.hostServiceVersion)
        else { return .needsHostService }
        return info.readOnly ? .readOnlyDevice : .available
    }

    public func sendWhenDoneQueues() async throws -> [SendWhenDoneQueue] {
        try await requireHostService(.agentObserver)
        let reply = try await withDeadline(HostCommandDeadline.standard) {
            try await self.send { .queueList(.init(requestId: $0)) }
        }
        guard case .queueListResult(let result) = reply else { throw HostServiceError.unexpectedResponse }
        return result.queues.map(SendWhenDoneQueue.init)
    }

    public func sendWhenDoneAdd(paneID: String, text: String, expectedSession: String) async throws -> String {
        try await requireHostService(.agentObserver)
        let reply = try await withDeadline(HostCommandDeadline.standard) {
            try await self.send { .queueAdd(.init(requestId: $0, paneId: paneID, text: text, expectedSession: expectedSession)) }
        }
        guard case .queueAddResult(let result) = reply else { throw HostServiceError.unexpectedResponse }
        return result.itemId
    }

    public func sendWhenDoneRemove(paneID: String, itemID: String) async throws {
        try await requireHostService(.agentObserver)
        let reply = try await withDeadline(HostCommandDeadline.standard) {
            try await self.send { .queueRemove(.init(requestId: $0, paneId: paneID, itemId: itemID)) }
        }
        guard case .queueRemoveResult = reply else { throw HostServiceError.unexpectedResponse }
    }

    public func sendWhenDoneReorder(paneID: String, itemIDs: [String]) async throws {
        try await requireHostService(.agentObserver)
        let reply = try await withDeadline(HostCommandDeadline.standard) {
            try await self.send { .queueReorder(.init(requestId: $0, paneId: paneID, itemIds: itemIDs)) }
        }
        guard case .queueReorderResult = reply else { throw HostServiceError.unexpectedResponse }
    }

    /// 這條連線上的 `queue.changed` 推送;連線結束時以連線錯誤結束，呼叫端重連後重新讀佇列。
    public func sendWhenDoneChanges() async throws -> AsyncThrowingStream<SendWhenDoneChange, any Error> {
        try await requireHostService(.agentObserver)
        let changes = try await liveSession().observeQueueChanges()
        return AsyncThrowingStream { continuation in
            let forwarding = Task {
                do {
                    for try await change in changes {
                        continuation.yield(SendWhenDoneChange(queue: SendWhenDoneQueue(change.queue), sentItemID: change.sentItemId))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in forwarding.cancel() }
        }
    }
}

extension SendWhenDoneQueue {
    init(_ queue: HostServiceProtocol.PaneQueue) {
        self.init(
            paneID: queue.paneId,
            items: queue.items.map { SendWhenDoneItem(id: $0.itemId, text: $0.text, expectedSession: $0.expectedSession) },
            pause: queue.paused.map { _ in .sessionChanged })
    }
}
