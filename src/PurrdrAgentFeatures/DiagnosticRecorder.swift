import Foundation
import PurrdrCore

/// 捲動卡頓記錄器的核心(只在聊天列表可見且 app 在前景時運作,否則零成本)。
///
/// 畫面回呼 `frame(...)` 只在記憶體裡累加(環形緩衝),**不做任何 I/O**;`flush()`(定時、停止時)才把緩衝交給儲存,
/// 儲存自己在背景佇列寫檔。連續卡幀合併成一個事件;每次捲動手勢結束記一筆摘要。
@MainActor
public final class DiagnosticRecorder {
    /// 預設的「畫面」識別(只有一個畫面時不必指定)。
    public static let defaultOwner = ObjectIdentifier(DiagnosticRecorder.self)

    /// 運作狀態變了(橋接層據此啟停 `CADisplayLink`)。每個聊天畫面各登記一個(以畫面識別區分)。
    public func observeRunning(owner: ObjectIdentifier = DiagnosticRecorder.defaultOwner, _ handler: @escaping @MainActor (Bool) -> Void) {
        runningObservers[owner] = handler
    }

    public func removeRunningObserver(owner: ObjectIdentifier = DiagnosticRecorder.defaultOwner) {
        runningObservers[owner] = nil
    }

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

    private let sink: any DiagnosticLogStoring
    private let defaults: UserDefaults
    private let system: @MainActor () -> HitchSystemState
    private let wallClock: @Sendable () -> Date
    private var buffer: HitchRingBuffer<DiagnosticEntry>
    private var runningObservers: [ObjectIdentifier: @MainActor (Bool) -> Void] = [:]
    /// 目前可見的聊天列表(可能同時有兩個:換頁轉場、iPad 多視窗);任一個可見就運作。
    private var visibleOwners: Set<ObjectIdentifier> = []
    private var display: (maxFramesPerSecond: Int, textSize: String)?
    private var isSceneActive = false
    private var olderLoading = false
    private var agentWorking = false
    private var lastTimestamp: Double?
    private var lastExpected = 0.0
    private var activity = HitchActivity()
    private var openEvent: OpenEvent?
    private var session: ScrollSession?

    public init(
        sink: any DiagnosticLogStoring, defaults: UserDefaults, system: @escaping @MainActor () -> HitchSystemState,
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

    public func setVisible(_ visible: Bool, owner: ObjectIdentifier = DiagnosticRecorder.defaultOwner) {
        if visible { visibleOwners.insert(owner) } else { visibleOwners.remove(owner) }
        updateRunning()
    }

    /// 目前畫面的更新率上限與字級類別(由畫面回報,寫進事件的系統狀態)。
    public func setDisplay(maxFramesPerSecond: Int, textSize: String) {
        display = (maxFramesPerSecond, textSize)
    }

    public func setSceneActive(_ active: Bool) {
        guard isSceneActive != active else { return }
        isSceneActive = active
        updateRunning()
    }

    private func updateRunning() {
        let shouldRun = isEnabled && !visibleOwners.isEmpty && isSceneActive
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
        for handler in runningObservers.values { handler(shouldRun) }
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

    /// 操作計時(#635):記錄開著才寫(不經緩衝)。
    public func recordTiming(_ timing: OperationTiming) {
        guard isEnabled else { return }
        sink.append([.timing(timing)])
    }

    /// 閃退記錄:一律寫(不看開關、不經緩衝)。
    public func recordCrash(_ record: CrashRecord) {
        sink.append([.crash(record)])
        publish(record)
    }

    /// MetricKit 的閃退報告:一律寫(不看開關、不經緩衝)。Swift 執行期錯誤沒有中止前的標記,只有這份報告,
    /// 所以也要通知(以報告轉成的閃退記錄)。
    public func recordCrashReport(_ report: MetricKitCrashReport) {
        sink.append([.crashReport(report)])
        publish(report.crashRecord)
    }

    /// 閃退記錄出現時通知(啟動提示用);各畫面各登記一個(以 `owner` 區分,同一個 owner 再登記會取代舊的)。
    /// 登記時若這次啟動已有記錄,立刻補送最近一筆。
    public func observeCrashes(owner: ObjectIdentifier = DiagnosticRecorder.defaultOwner, _ handler: @escaping @MainActor (CrashRecord) -> Void) {
        crashObservers[owner] = handler
        if let latestCrash { handler(latestCrash) }
    }

    public func removeCrashObserver(owner: ObjectIdentifier = DiagnosticRecorder.defaultOwner) {
        crashObservers[owner] = nil
    }

    private var latestCrash: CrashRecord?
    private var crashObservers: [ObjectIdentifier: @MainActor (CrashRecord) -> Void] = [:]

    private func publish(_ record: CrashRecord) {
        latestCrash = record
        for handler in crashObservers.values { handler(record) }
    }

    // MARK: - 設定頁

    public func exportFile() async -> URL? {
        flush()
        return await sink.exportFile(meta: .meta(currentSystem(), at: wallClock()))
    }

    public func clear() async {
        buffer.removeAll()
        openEvent = nil
        session = nil
        await sink.clear()
    }

    private func currentSystem() -> HitchSystemState {
        var state = system()
        if let display {
            state.maxFramesPerSecond = display.maxFramesPerSecond
            state.textSize = display.textSize
        }
        return state
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
        activity.offsetCorrectionPoints = DiagnosticLogEncoder.round1(activity.offsetCorrectionPoints)
        buffer.append(.hitch(HitchEvent(
            timestamp: wallClock(),
            milliseconds: DiagnosticLogEncoder.round1(event.milliseconds), frames: event.frames, droppedFrames: event.droppedFrames,
            scroll: event.start.scroll, offsetY: DiagnosticLogEncoder.round1(event.start.offsetY),
            velocityY: DiagnosticLogEncoder.round1(event.start.velocityY), visibleCells: event.start.visibleCells,
            activity: activity, olderLoading: event.start.olderLoading, agentWorking: event.start.agentWorking, system: currentSystem())))
    }

    private func finishScrollSession() {
        guard let finished = session else { return }
        session = nil
        guard finished.frames > 0, finished.seconds > 0 else { return }
        buffer.append(.scroll(ScrollSummary(
            timestamp: wallClock(), seconds: finished.seconds, frames: finished.frames,
            averageIntervalMilliseconds: DiagnosticLogEncoder.round1(finished.seconds / Double(finished.frames) * 1000),
            maxIntervalMilliseconds: DiagnosticLogEncoder.round1(finished.maxInterval * 1000), hitchEvents: finished.hitchEvents,
            hitchMilliseconds: DiagnosticLogEncoder.round1(finished.hitchSeconds * 1000),
            hitchTimeRatio: finished.hitchSeconds / finished.seconds, agentWorking: agentWorking, system: currentSystem())))
    }
}
