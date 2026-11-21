import Foundation

/// Send When Done 佇列裡的一則訊息(#305):排在主機上，Agent 做完後依序送出。
public struct SendWhenDoneItem: Equatable, Sendable, Identifiable {
    public let id: String
    public let text: String
    /// 排入時對象的 session;要送出時 Agent 的 session 已不是它就不送。
    public let expectedSession: String

    public init(id: String, text: String, expectedSession: String) {
        self.id = id
        self.text = text
        self.expectedSession = expectedSession
    }
}

/// 佇列暫停的原因。
public enum SendWhenDonePause: Equatable, Sendable {
    /// 要送出時 Agent 的 session 已不是第一則排入時的 session:沒有送出，移除或重排第一則後解除。
    case sessionChanged
}

/// 一個 pane 的 Send When Done 佇列，依送出順序。
public struct SendWhenDoneQueue: Equatable, Sendable {
    public let paneID: String
    public var items: [SendWhenDoneItem]
    public var pause: SendWhenDonePause?

    public init(paneID: String, items: [SendWhenDoneItem], pause: SendWhenDonePause? = nil) {
        self.paneID = paneID
        self.items = items
        self.pause = pause
    }
}

/// 主機推來的佇列變動(新增、刪除、重排、送出或暫停)。
public struct SendWhenDoneChange: Equatable, Sendable {
    public let queue: SendWhenDoneQueue
    /// 這次變動是因為這則已送出。
    public let sentItemID: String?

    public init(queue: SendWhenDoneQueue, sentItemID: String? = nil) {
        self.queue = queue
        self.sentItemID = sentItemID
    }
}

/// 這支裝置能不能用 Send When Done。
public enum SendWhenDoneAvailability: Equatable, Sendable {
    case available
    /// 主機沒有主機服務(SSH 主機)或版本太舊。
    case needsHostService
    /// 這支裝置配對成唯讀。
    case readOnlyDevice
}

/// 主機端的 Send When Done 佇列(主機服務 0.7.0 起的 `queue.*` 與推送 `queue.changed`)。
/// 只有 HTTPS 主機提供;佇列存在主機上，app 關掉也照送。
public protocol SendWhenDoneHosting: Sendable {
    func sendWhenDoneAvailability() async -> SendWhenDoneAvailability
    /// 所有有排隊訊息的 pane 的佇列。
    func sendWhenDoneQueues() async throws -> [SendWhenDoneQueue]
    /// 排到 pane 佇列的尾端，回傳訊息的識別碼。佇列滿了丟 `HostServiceError.queueFull`。
    func sendWhenDoneAdd(paneID: String, text: String, expectedSession: String) async throws -> String
    /// 不在佇列裡丟 `HostServiceError.queueItemUnknown`。
    func sendWhenDoneRemove(paneID: String, itemID: String) async throws
    /// `itemIDs` 必須恰好是目前佇列的所有識別碼。
    func sendWhenDoneReorder(paneID: String, itemIDs: [String]) async throws
    /// 佇列變動的串流;連線結束時以連線錯誤結束(呼叫端重連後重新讀佇列)。
    func sendWhenDoneChanges() async throws -> AsyncThrowingStream<SendWhenDoneChange, any Error>
}
