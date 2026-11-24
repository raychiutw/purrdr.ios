import Foundation

/// 捲動卡頓記錄器的核心(只在聊天列表可見且 app 在前景時運作,否則零成本)。
///
/// 畫面回呼 `frame(...)` 只在記憶體裡累加(環形緩衝),**不做任何 I/O**;`flush()`(定時、停止時)才把緩衝交給儲存,
/// 儲存自己在背景佇列寫檔。連續卡幀合併成一個事件;每次捲動手勢結束記一筆摘要。
@MainActor
public final class HitchRecorder {
    /// 運作狀態變了(橋接層據此啟停 `CADisplayLink`)。
    public var onRunningChanged: (Bool) -> Void = { _ in }

    /// 設定頁的「記錄捲動卡頓」開關(預設開啟;存進 `UserDefaults`);關閉時立刻停止並丟掉還沒寫出的緩衝。
    public var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: HitchLogSettings.enabledKey)
            updateRunning()
        }
    }

    public private(set) var isRunning = false

    private struct OpenEvent {
        var start: HitchFrameStart
        var milliseconds = 0.0
        var frames = 0
        var droppedFrames = 0
        var activity = HitchActivity()
    }

    private struct HitchFrameStart {
        var scroll: HitchScrollState
        var offsetY: Double
        var velocityY: Double
        var visibleCells: Int
        var olderLoading: Bool
        var agentWorking: Bool
    }

    private struct ScrollSession {
        var seconds = 0.0
        var frames = 0
        var maxInterval = 0.0
        var hitchEvents = 0
        var hitchSeconds = 0.0
    }

    private let sink: any HitchLogStoring
    private let defaults: UserDefaults
    private let system: @MainActor () -> HitchSystemState
    private let wallClock: @Sendable () -> Date
    private var buffer: HitchRingBuffer<HitchEntry>
    private var isVisible = false
    private var isSceneActive = false
    private var olderLoading = false
    private var agentWorking = false
    private var lastTimestamp: Double?
    private var lastExpected = 0.0
    private var activity = HitchActivity()
    private var openEvent: OpenEvent?
    private var session: ScrollSession?

    public init(
        sink: any HitchLogStoring, defaults: UserDefaults, system: @escaping @MainActor () -> HitchSystemState,
        wallClock: @escaping @Sendable () -> Date = { Date() }, bufferCapacity: Int = 512
    ) {
        self.sink = sink
        self.defaults = defaults
        self.system = system
        self.wallClock = wallClock
        self.buffer = HitchRingBuffer(capacity: bufferCapacity)
        self.isEnabled = HitchLogSettings.isEnabled(defaults)
    }

    // MARK: - 運作條件

    public func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        updateRunning()
    }

    public func setSceneActive(_ active: Bool) {
        guard isSceneActive != active else { return }
        isSceneActive = active
        updateRunning()
    }

    private func updateRunning() {
        let shouldRun = isEnabled && isVisible && isSceneActive
        guard shouldRun != isRunning else { return }
        isRunning = shouldRun
        if shouldRun {
            lastTimestamp = nil
            activity = HitchActivity()
        } else if isEnabled {
            finishOpenRecords()
            flush()
        } else {
            openEvent = nil
            session = nil
            buffer.removeAll()
        }
        onRunningChanged(shouldRun)
    }

    // MARK: - 列表回報

    /// 目前列表是否載入較舊的訊息中、Agent 是否工作中(只記旗標)。
    public func setOlderLoading(_ loading: Bool) { olderLoading = loading }
    public func setAgentWorking(_ working: Bool) { agentWorking = working }

    public func note(_ kind: HitchActivityKind) {
        guard isRunning else { return }
        switch kind {
        case .batchApply: activity.batchApplies += 1
        case .fit(let milliseconds):
            activity.fitCount += 1
            activity.fitMilliseconds += milliseconds
        case .offsetCorrection(let points):
            activity.offsetCorrections += 1
            activity.offsetCorrectionPoints += abs(points)
        case .contentSizeChange(let points):
            activity.contentSizeChanges += 1
            activity.contentSizeChangePoints += abs(points)
        case .reconfigure(let count): activity.reconfigures += count
        case .contentUpdate: activity.contentUpdates += 1
        }
    }

    /// 每個畫面更新一次(`CADisplayLink` 回呼):`expectedInterval` 是這一幀的目標間隔;
    /// 實際間隔以前一幀的目標間隔判定。`visibleCells` 只在開出事件時才求值。
    public func frame(
        timestamp: Double, expectedInterval: Double, scroll: HitchScrollState, offsetY: Double, velocityY: Double,
        visibleCells: () -> Int
    ) {
        guard isRunning else { return }
        defer {
            lastTimestamp = timestamp
            lastExpected = expectedInterval
        }
        guard let last = lastTimestamp, timestamp > last else { return }
        let interval = timestamp - last
        let isHitch = HitchFrameClassifier.isHitch(interval: interval, expected: lastExpected)

        // 捲動手勢:第一個非閒置的畫面開始,回到閒置結束。
        if scroll == .idle {
            finishScrollSession()
        } else {
            var current = session ?? ScrollSession()
            current.frames += 1
            current.seconds += interval
            current.maxInterval = max(current.maxInterval, interval)
            if isHitch { current.hitchSeconds += interval - lastExpected }
            session = current
        }

        guard isHitch else {
            finishOpenEvent()
            activity = HitchActivity()
            return
        }
        // 閒置時沒有同時的活動就不記:系統調降更新率不是卡頓。
        if openEvent == nil, scroll == .idle, activity.isEmpty {
            return
        }
        if openEvent == nil {
            openEvent = OpenEvent(start: HitchFrameStart(
                scroll: scroll, offsetY: offsetY, velocityY: velocityY, visibleCells: visibleCells(),
                olderLoading: olderLoading, agentWorking: agentWorking))
            session?.hitchEvents += 1
        }
        openEvent?.milliseconds += interval * 1000
        openEvent?.frames += 1
        openEvent?.droppedFrames += HitchFrameClassifier.droppedFrames(interval: interval, expected: lastExpected)
        openEvent?.activity.merge(activity)
        activity = HitchActivity()
    }

    /// 把緩衝交給儲存(定時與停止時呼叫);沒有東西就不呼叫儲存。
    public func flush() {
        let entries = buffer.drain()
        guard !entries.isEmpty else { return }
        sink.append(entries)
    }

    /// MetricKit 的每日摘要(不經緩衝;沒開啟記錄時不寫)。
    public func recordMetrics(_ digest: HitchMetricsDigest) {
        guard isEnabled else { return }
        sink.append([.metrics(digest)])
    }

    // MARK: - 設定頁

    public func exportFile() async -> URL? {
        flush()
        return await sink.exportFile(meta: .meta(system(), at: wallClock()))
    }

    public func clear() async {
        buffer.removeAll()
        openEvent = nil
        session = nil
        await sink.clear()
    }

    // MARK: - 收尾

    private func finishOpenRecords() {
        finishOpenEvent()
        finishScrollSession()
    }

    private func finishOpenEvent() {
        guard let event = openEvent else { return }
        openEvent = nil
        var activity = event.activity
        activity.offsetCorrectionPoints = HitchLogEncoder.round1(activity.offsetCorrectionPoints)
        buffer.append(.hitch(HitchEvent(
            timestamp: wallClock(),
            milliseconds: HitchLogEncoder.round1(event.milliseconds), frames: event.frames, droppedFrames: event.droppedFrames,
            scroll: event.start.scroll, offsetY: HitchLogEncoder.round1(event.start.offsetY),
            velocityY: HitchLogEncoder.round1(event.start.velocityY), visibleCells: event.start.visibleCells,
            activity: activity, olderLoading: event.start.olderLoading, agentWorking: event.start.agentWorking, system: system())))
    }

    private func finishScrollSession() {
        guard let finished = session else { return }
        session = nil
        guard finished.frames > 0, finished.seconds > 0 else { return }
        buffer.append(.scroll(ScrollSummary(
            timestamp: wallClock(), seconds: finished.seconds, frames: finished.frames,
            averageIntervalMilliseconds: HitchLogEncoder.round1(finished.seconds / Double(finished.frames) * 1000),
            maxIntervalMilliseconds: HitchLogEncoder.round1(finished.maxInterval * 1000), hitchEvents: finished.hitchEvents,
            hitchMilliseconds: HitchLogEncoder.round1(finished.hitchSeconds * 1000),
            hitchTimeRatio: finished.hitchSeconds / finished.seconds, agentWorking: agentWorking, system: system())))
    }
}
