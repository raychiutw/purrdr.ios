import Foundation
import Observation
import PurrdrCore

/// 一個聊天(pane)的 Send When Done(#305,spec #298):輸入列的「做完再送」開著時，送出的訊息排進主機上的佇列，
/// Agent 做完後依序送出。佇列存在主機上(app 關掉也照送);這裡只是它的畫面狀態:讀回、跟著 `queue.changed` 更新。
///
/// 只有 HTTPS 主機(主機服務 0.7.0 起)有;SSH 主機、舊版主機服務與唯讀裝置的開關停用並說明。
@MainActor
@Observable
public final class SendWhenDoneModel {
    public private(set) var availability: SendWhenDoneAvailability
    /// 這個 pane 排隊中的訊息，依送出順序。
    public private(set) var items: [SendWhenDoneItem] = []
    /// 佇列暫停的原因(泡泡上方說明);沒暫停是 `nil`。
    public private(set) var pause: SendWhenDonePause?
    /// 第一次讀回佇列後為 `true`。
    public private(set) var hasLoaded = false
    /// 排入、刪除失敗的說明;下一次操作成功時清掉。
    public private(set) var notice: String?
    private var requested = false

    @ObservationIgnored private let host: (any SendWhenDoneHosting)?
    @ObservationIgnored private let paneID: String
    @ObservationIgnored private let sleep: Sleep

    /// - Parameter host: 主機端佇列;`nil` 是沒有主機服務的連線方式(SSH、Demo)。
    public init(host: (any SendWhenDoneHosting)?, paneID: String, sleep: @escaping Sleep = Sleeping.task) {
        self.host = host
        self.paneID = paneID
        self.sleep = sleep
        availability = .needsHostService
    }

    /// 「做完再送」開著，而且這支裝置能用。
    public var isEnabled: Bool { requested && availability == .available }

    /// 系統開關的繫結值:可用時才會被切換(停用的 `Toggle` 不會呼叫 setter)。
    public var isRequested: Bool {
        get { isEnabled }
        set {
            guard availability == .available else { return }
            requested = newValue
            notice = nil
        }
    }

    /// 開關停用的原因,寫在開關下方的說明(取代點了跳對話框);可用時是 `nil`。
    public var unavailableReason: String? {
        switch availability {
        case .available: nil
        case .needsHostService:
            String(localized: "Send When Done needs the Purrdr host service on this host. Install or update it first.")
        case .readOnlyDevice:
            String(localized: "This device is paired read-only, so it can’t queue messages.")
        }
    }

    /// 點開關:可用時切換。
    public func toggle() {
        isRequested = !isEnabled
    }

    /// 讀回佇列並跟著主機的推送更新，直到取消。連線斷了就退避後重連、重讀(1 秒起倍增、上限 30 秒)。
    public func run() async {
        guard let host else { return }
        availability = await host.sendWhenDoneAvailability()
        guard availability == .available else { return }
        var delay = Duration.seconds(1)
        while !Task.isCancelled {
            do {
                // 先訂閱再讀佇列:中間的變動不會漏掉。
                let changes = try await host.sendWhenDoneChanges()
                apply(try await host.sendWhenDoneQueues())
                delay = .seconds(1)
                for try await change in changes { apply(change.queue) }
            } catch is CancellationError {
                return
            } catch {
                // 連不上或連線結束:退避後重來。
            }
            do { try await sleep(delay) } catch { return }
            delay = min(delay * 2, .seconds(30))
        }
    }

    /// 排到佇列尾端。失敗時留下說明並回 `false`(呼叫端把文字放回輸入框)。
    func add(text: String, expectedSession: String?) async -> Bool {
        guard let host else { return false }
        guard let expectedSession else {
            notice = String(localized: "This chat isn’t ready yet, so the message can’t be queued. Try again in a moment.")
            return false
        }
        do {
            _ = try await host.sendWhenDoneAdd(paneID: paneID, text: text, expectedSession: expectedSession)
            notice = nil
            return true
        } catch {
            notice = HostErrorText.message(for: error)
            return false
        }
    }

    /// 刪除一則。已不在佇列(剛送出或別支裝置刪了)不算失敗。
    public func remove(_ id: SendWhenDoneItem.ID) async {
        _ = await removeItem(id)
    }

    /// 編輯:從佇列拿掉並交回文字(放回輸入框修改)。拿不掉(連線失敗、已送出)回 `nil`,訊息留在佇列。
    public func takeBack(_ id: SendWhenDoneItem.ID) async -> String? {
        guard let text = items.first(where: { $0.id == id })?.text else { return nil }
        return await removeItem(id) ? text : nil
    }

    /// 這則可不可以往前(`offset` < 0)或往後(> 0)移動 `offset` 格。
    public func canMove(_ id: SendWhenDoneItem.ID, by offset: Int) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        return items.indices.contains(index + offset)
    }

    /// 調整順序(送出的先後):這則往前或往後移動 `offset` 格。畫面先換、再請主機重排;
    /// 主機拒絕或連不上時換回原本的順序並留下說明,佇列已不同(剛送出或別支裝置改了)時重讀。
    public func move(_ id: SendWhenDoneItem.ID, by offset: Int) async {
        guard canMove(id, by: offset), let host, let index = items.firstIndex(where: { $0.id == id }) else { return }
        let before = items
        var reordered = items
        reordered.insert(reordered.remove(at: index), at: index + offset)
        items = reordered
        do {
            try await host.sendWhenDoneReorder(paneID: paneID, itemIDs: reordered.map(\.id))
            notice = nil
        } catch {
            items = before
            notice = HostErrorText.message(for: error)
            if let queues = try? await host.sendWhenDoneQueues() { apply(queues) }
        }
    }

    /// - Returns: 這則是不是被這次操作從佇列拿掉的。
    private func removeItem(_ id: SendWhenDoneItem.ID) async -> Bool {
        guard let host else { return false }
        do {
            try await host.sendWhenDoneRemove(paneID: paneID, itemID: id)
            notice = nil
            return true
        } catch HostServiceError.queueItemUnknown {
            // 已經不在佇列：重讀一次，畫面對齊主機。
            if let queues = try? await host.sendWhenDoneQueues() { apply(queues) }
            return false
        } catch {
            notice = HostErrorText.message(for: error)
            return false
        }
    }

    private func apply(_ queues: [SendWhenDoneQueue]) {
        apply(queues.first { $0.paneID == paneID } ?? SendWhenDoneQueue(paneID: paneID, items: []))
        hasLoaded = true
    }

    private func apply(_ queue: SendWhenDoneQueue) {
        guard queue.paneID == paneID else { return }
        items = queue.items
        pause = queue.pause
    }
}

/// 送出管線的 Send When Done 步驟(#305):「做完再送」開著時，訊息排進主機的佇列(輸入框維持清空);
/// 排不進去(佇列滿了、連不上、還不知道 session)時文字放回輸入框，原因在 `SendWhenDoneModel.notice`。關著時原樣通過。
@MainActor
public struct SendWhenDoneStep: SendStep {
    public let model: SendWhenDoneModel

    public init(model: SendWhenDoneModel) {
        self.model = model
    }

    public func process(_ prompt: OutgoingPrompt, clock: SendPipelineClock) async -> SendStepResult {
        guard model.isEnabled else { return .proceed(prompt) }
        let queued = await model.add(text: prompt.text, expectedSession: prompt.expectedSession)
        return .halt(SendHalt(restoresDraft: !queued))
    }
}
