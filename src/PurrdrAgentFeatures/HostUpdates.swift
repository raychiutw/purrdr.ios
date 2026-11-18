import Foundation
import Observation
import PurrdrCore

/// 主機更新來源：每台主機一個，訂閱 herdr 事件並維持最新的主機快照;畫面都從它讀，不各自讀快照(#160)。
@MainActor
@Observable
public final class HostUpdates {
    public enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    public private(set) var phase: Phase = .loading

    /// 最後一次成功讀到的主機快照。讀取失敗時保留。
    public private(set) var snapshot: HostSnapshot?

    /// 即時更新(`run()`),由所有顯示這台主機的畫面與視窗共用：iPad 多視窗時只跑一份(#31)。
    @ObservationIgnored public private(set) lazy var liveUpdates = SharedRun { [weak self] in await self?.run() }

    /// 要不要訂閱版面事件(#40:只有 Spaces 檢視要)。執行中改變時，關掉目前的訂閱、立刻用新的清單重新訂閱。
    public var subscribesToLayout = false {
        didSet { if subscribesToLayout != oldValue { endSubscription?() } }
    }

    /// 即時更新停著，等使用者按「再試一次」(取消了 Tailscale 重新驗證)。
    public var isWaitingForRetry: Bool { checkCancelWaiter != nil }

    /// 事件訂閱開著、而且訂閱開始後已經對帳過：`snapshot` 會隨事件更新，畫面不必自己讀快照(#163)。
    public private(set) var isSubscribed = false

    /// 快照讀取進行中又有事件到達：讀完後會再讀一次(期間的事件都併成這一次)。
    package private(set) var hasQueuedResync = false

    /// 一個 Agent 的變化：先給目前的值(還沒讀到快照時等第一份),之後快照裡它有變才再給;不在快照裡是 `nil`。
    public func changes(for paneID: String) -> AsyncStream<Agent?> {
        let (stream, continuation) = AsyncStream<Agent?>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        let watcher = PaneWatcher(paneID: paneID, continuation: continuation)
        paneWatchers[id] = watcher
        if let snapshot { paneWatchers[id]?.publish(from: snapshot) }
        continuation.onTermination = { [weak self] _ in Task { @MainActor [weak self] in self?.paneWatchers[id] = nil } }
        return stream
    }

    @ObservationIgnored private var paneWatchers: [UUID: PaneWatcher] = [:]

    /// 每次讀到快照後、這次讀取結束前執行(Agent 列表在這裡更新預覽);期間到達的事件一樣合併。
    @ObservationIgnored var afterSnapshot: (@MainActor () async -> Void)?

    private let client: HerdrClient
    private let sleep: Sleep
    @ObservationIgnored private var endSubscription: (() -> Void)?
    private var checkCancelWaiter: CheckedContinuation<Void, Never>?
    private var retryRequested = false
    private var retryWaiter: CheckedContinuation<Void, Never>?
    /// 快照讀取進行中(含讀完後的 `afterSnapshot`)。
    @ObservationIgnored private var isReading = false
    /// 這一輪訂閱收到 ack 了(退避歸零)。
    @ObservationIgnored private var subscriptionStarted = false

    /// - Parameter sleep: 退避用的等待;測試注入假的。
    public init(client: HerdrClient, sleep: @escaping Sleep = Sleeping.task) {
        self.client = client
        self.sleep = sleep
    }

    /// 讀一次快照。即時更新因取消 Tailscale 重新驗證而停著時，改為讓它重新開始。
    public func load() async {
        if let checkCancelWaiter {
            self.checkCancelWaiter = nil
            phase = .loading
            checkCancelWaiter.resume()
            return
        }
        do {
            try await refresh()
        } catch {
            fail(with: error)
        }
    }

    /// 即時更新，直到所在的 task 被取消(行為規格 §3.7)。
    ///
    /// - 先讀快照得知有哪些 Agent pane,再訂閱每個 pane 的狀態改變與全主機事件。
    /// - 事件不重播，所以訂閱開始(ack)時重讀一次對帳;之後事件只當「重讀」的觸發。
    /// - 同時只跑一個快照讀取，期間到達的事件合併成讀完後的「再一次」(不用固定延遲去抖)。
    /// - `events_lost`:立刻重新訂閱並重讀。
    /// - Agent pane 的集合變了，或換了檢視(`subscribesToLayout`):關掉舊的、用新清單重新訂閱。
    /// - herdr 沒有事件訂閱(`herdrCapabilityMissing`):不算失敗，每 30 秒重讀。
    /// - 其他失敗：退避 1 秒起倍增、上限 30 秒;收到 ack 即歸零。
    /// - 使用者取消了 Tailscale 重新驗證或權杖失效：不自動重試，等「再試一次」。
    public func run() async {
        var failures = 0
        var needsSnapshot = true
        while !Task.isCancelled {
            var resubscribeNow = false
            do {
                if needsSnapshot { try await refresh() }
                needsSnapshot = false
                let panes = agentPaneIDs
                let layout = subscribesToLayout
                let subscription: AsyncThrowingStream<HerdrEvent, any Error>
                do {
                    subscription = try await client.subscribe(
                        panes.map(EventSubscription.agentStatusChanged) + EventSubscription.hostWide + (layout ? EventSubscription.layout : []))
                } catch HostServiceError.herdrCapabilityMissing {
                    try await sleep(Self.pollingInterval)
                    needsSnapshot = true
                    continue
                }
                subscriptionStarted = false
                let triggers = coalesced(subscription)
                defer {
                    endSubscription?()
                    endSubscription = nil
                    isSubscribed = false
                }
                for try await _ in triggers {
                    if subscriptionStarted { failures = 0 }
                    hasQueuedResync = false
                    try await refresh()
                    if subscriptionStarted { isSubscribed = true }
                    if Set(agentPaneIDs) != Set(panes) || subscribesToLayout != layout { break }
                }
                resubscribeNow = Set(agentPaneIDs) != Set(panes) || subscribesToLayout != layout
            } catch HerdrError.herdr(code: "events_lost", _) {
                needsSnapshot = true
                resubscribeNow = true
            } catch let error as HostServiceError where error.requiresPairing {
                fail(with: error)
                await waitForUserRetry()
                if Task.isCancelled { return }
                failures = 0
                needsSnapshot = true
                continue
            } catch SSHConnectionError.tailscaleCheckCancelled {
                fail(with: SSHConnectionError.tailscaleCheckCancelled)
                await waitForUserRetry()
                if Task.isCancelled { return }
                failures = 0
                needsSnapshot = true
                continue
            } catch {
                if Task.isCancelled { return }
                fail(with: error)
                needsSnapshot = true
            }
            if Task.isCancelled { return }
            guard !resubscribeNow else { continue }
            failures += 1
            needsSnapshot = true
            do {
                try await backoff(Self.backoff(afterFailures: failures))
            } catch {
                return
            }
        }
    }

    /// 使用者按「重試」或網路恢復：正在退避就立刻重連;正在連就讓下一次退避直接跳過。
    public func retryNow() {
        if let waiter = retryWaiter {
            retryWaiter = nil
            waiter.resume()
        } else {
            retryRequested = true
        }
    }

    /// 沒有事件訂閱可用時重讀的間隔。
    package static let pollingInterval: Duration = .seconds(30)

    /// 1 秒起倍增、上限 30 秒。
    package static func backoff(afterFailures failures: Int) -> Duration {
        .seconds(min(30, 1 << min(failures - 1, 5)))
    }

    private var agentPaneIDs: [String] { snapshot?.agents.map(\.paneID) ?? [] }

    private func refresh() async throws {
        isReading = true
        defer { isReading = false }
        let fresh = try await client.snapshot()
        snapshot = fresh
        phase = .loaded
        for id in paneWatchers.keys { paneWatchers[id]?.publish(from: fresh) }
        await afterSnapshot?()
    }

    /// 把訂閱的事件併成「要重讀」的觸發：最多暫存一個，讀取期間的事件都併進它。
    /// `endSubscription` 能從外面結束它(結束時取消轉送，關掉底層的訂閱通道)。
    private func coalesced(_ events: AsyncThrowingStream<HerdrEvent, any Error>) -> AsyncThrowingStream<Void, any Error> {
        let (stream, continuation) = AsyncThrowingStream<Void, any Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let forward = Task { @MainActor [weak self] in
            do {
                for try await event in events {
                    if event == .subscriptionStarted { self?.subscriptionStarted = true }
                    if self?.isReading == true { self?.hasQueuedResync = true }
                    continuation.yield()
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in forward.cancel() }
        endSubscription = { continuation.finish() }
        return stream
    }

    /// 退避等待：時間到，或有人要求立刻重試。
    private func backoff(_ duration: Duration) async throws {
        if retryRequested {
            retryRequested = false
            return
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [sleep] in try await sleep(duration) }
            group.addTask { await self.waitForRetry() }
            try await group.next()
            group.cancelAll()
        }
    }

    /// 等使用者按「再試一次」(`load()`);所在的 task 被取消時也結束。
    private func waitForUserRetry() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    checkCancelWaiter = continuation
                }
            }
        } onCancel: {
            Task { @MainActor in self.resumeCheckCancelWaiter() }
        }
    }

    private func resumeCheckCancelWaiter() {
        let waiter = checkCancelWaiter
        checkCancelWaiter = nil
        waiter?.resume()
    }

    private func waitForRetry() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    retryWaiter = continuation
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancelRetryWait() }
        }
    }

    private func cancelRetryWait() {
        retryWaiter?.resume()
        retryWaiter = nil
    }

    private func fail(with error: any Error) {
        switch error {
        case HerdrError.herdr(_, let message):
            // 未知碼保留 herdr 原文(行為規格 §3.8)。
            phase = .failed(message)
        case is SSHConnectionError, is HostServiceError:
            phase = .failed(HostErrorText.message(for: error))
        default:
            phase = .failed(String(localized: "Couldn’t read this host’s herdr status."))
        }
    }
}

/// 一個 `changes(for:)` 的訂閱者：只在它看的 Agent 改變時給值。
private struct PaneWatcher {
    let paneID: String
    let continuation: AsyncStream<Agent?>.Continuation
    private var last: Agent??

    init(paneID: String, continuation: AsyncStream<Agent?>.Continuation) {
        self.paneID = paneID
        self.continuation = continuation
    }

    mutating func publish(from snapshot: HostSnapshot) {
        let agent = snapshot.agents.first { $0.paneID == paneID }
        guard last != .some(agent) else { return }
        last = .some(agent)
        continuation.yield(agent)
    }
}
