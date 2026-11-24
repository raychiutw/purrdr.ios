import Foundation

// 捲動卡頓記錄器的純邏輯(不 import UIKit／MetricKit):畫面更新間隔的判定、記錄的型別、環形緩衝、大小上限、JSON Lines 編碼。
// UIKit／MetricKit 的橋接在 PurrdrFeatures(`ChatHitchMonitor`、`HitchMetricKitSubscriber`、`HitchLogFile`)。
// 只記數字與旗標:不含對話內容、主機名稱、路徑或任何使用者輸入。

/// 聊天列表的捲動狀態。
public enum HitchScrollState: String, Sendable, Equatable {
    case idle, dragging, decelerating
}

/// 畫面更新間隔的卡幀判定。
public enum HitchFrameClassifier {
    /// 間隔超過目標間隔的這個倍數才算卡幀(120 Hz 的 8.33 ms 到 12.5 ms 以內都不算)。
    public static let tolerance = 1.5

    /// 目標間隔由 `CADisplayLink`(`targetTimestamp - timestamp`)給,所以 60 Hz 與 ProMotion 120 Hz 都適用。
    public static func isHitch(interval: Double, expected: Double) -> Bool {
        expected > 0 && interval > expected * tolerance
    }

    /// 這個間隔掉了幾幀(相當於幾幀減 1;卡幀至少算 1)。
    public static func droppedFrames(interval: Double, expected: Double) -> Int {
        guard expected > 0 else { return 0 }
        return max(1, Int((interval / expected).rounded()) - 1)
    }
}

/// 記錄當時的系統狀態(全部是數字、旗標與機型;沒有使用者資料)。
public struct HitchSystemState: Equatable, Sendable {
    public var thermal: String
    public var lowPower: Bool
    public var reduceTransparency: Bool
    public var reduceMotion: Bool
    /// 機型代碼(例如 iPhone18,1),不是裝置名稱。
    public var device: String
    public var os: String
    public var app: String
    public var textSize: String
    public var maxFramesPerSecond: Int

    public init(
        thermal: String, lowPower: Bool, reduceTransparency: Bool, reduceMotion: Bool,
        device: String, os: String, app: String, textSize: String, maxFramesPerSecond: Int
    ) {
        self.thermal = thermal
        self.lowPower = lowPower
        self.reduceTransparency = reduceTransparency
        self.reduceMotion = reduceMotion
        self.device = device
        self.os = os
        self.app = app
        self.textSize = textSize
        self.maxFramesPerSecond = maxFramesPerSecond
    }
}

/// 聊天列表在兩個畫面更新之間同時在做的事(累計;每個畫面更新後歸零)。
public struct HitchActivity: Equatable, Sendable {
    public var batchApplies = 0
    public var fitCount = 0
    public var fitMilliseconds = 0.0
    public var offsetCorrections = 0
    public var offsetCorrectionPoints = 0.0
    public var contentSizeChanges = 0
    public var contentSizeChangePoints = 0.0
    public var reconfigures = 0
    public var contentUpdates = 0

    public init() {}

    public var isEmpty: Bool { self == HitchActivity() }

    mutating func merge(_ other: HitchActivity) {
        batchApplies += other.batchApplies
        fitCount += other.fitCount
        fitMilliseconds += other.fitMilliseconds
        offsetCorrections += other.offsetCorrections
        offsetCorrectionPoints += other.offsetCorrectionPoints
        contentSizeChanges += other.contentSizeChanges
        contentSizeChangePoints += other.contentSizeChangePoints
        reconfigures += other.reconfigures
        contentUpdates += other.contentUpdates
    }
}

/// 列表回報的一件事。
public enum HitchActivityKind: Sendable {
    /// 內容批次套用(diffable snapshot)。
    case batchApply
    /// 一列自適應高度(`preferredLayoutAttributesFitting`)花的毫秒。
    case fit(milliseconds: Double)
    /// 程式修正 `contentOffset`(位移量,有正負,反向位移會是負的)。
    case offsetCorrection(points: Double)
    /// `contentSize` 變了(變動量)。
    case contentSizeChange(points: Double)
    /// `UIHostingConfiguration` 重新配置(reconfigure)的列數。
    case reconfigure(count: Int)
    /// 收到(內容有變的)列表內容更新,例如工作中計時器或預覽造成的更新。
    case contentUpdate
}

/// 一個卡幀事件(連續卡幀合併成一個)。
public struct HitchEvent: Equatable, Sendable {
    public var timestamp: Date
    public var milliseconds: Double
    public var frames: Int
    public var droppedFrames: Int
    public var scroll: HitchScrollState
    public var offsetY: Double
    public var velocityY: Double
    public var visibleCells: Int
    public var activity: HitchActivity
    public var olderLoading: Bool
    public var agentWorking: Bool
    public var system: HitchSystemState

    public init(
        timestamp: Date, milliseconds: Double, frames: Int, droppedFrames: Int, scroll: HitchScrollState, offsetY: Double,
        velocityY: Double, visibleCells: Int, activity: HitchActivity, olderLoading: Bool, agentWorking: Bool, system: HitchSystemState
    ) {
        self.timestamp = timestamp
        self.milliseconds = milliseconds
        self.frames = frames
        self.droppedFrames = droppedFrames
        self.scroll = scroll
        self.offsetY = offsetY
        self.velocityY = velocityY
        self.visibleCells = visibleCells
        self.activity = activity
        self.olderLoading = olderLoading
        self.agentWorking = agentWorking
        self.system = system
    }
}

/// 一次捲動手勢(拖曳到減速結束)的摘要。
public struct ScrollSummary: Equatable, Sendable {
    public var timestamp: Date
    public var seconds: Double
    public var frames: Int
    public var averageIntervalMilliseconds: Double
    public var maxIntervalMilliseconds: Double
    public var hitchEvents: Int
    public var hitchMilliseconds: Double
    /// 卡幀時間占比 = 超出目標間隔的總時間 ÷ 捲動秒數。
    public var hitchTimeRatio: Double
    public var agentWorking: Bool
    public var system: HitchSystemState
}

/// MetricKit 每日 payload 的摘要。
public struct HitchMetricsDigest: Equatable, Sendable {
    public var periodStart: Date
    public var periodEnd: Date
    /// `MXAnimationMetric.scrollHitchTimeRatio`(沒有時是 nil)。
    public var scrollHitchTimeRatio: Double?
    public var hangCount: Int
    public var longestHangSeconds: Double
    public var app: String
    public var os: String

    public init(
        periodStart: Date, periodEnd: Date, scrollHitchTimeRatio: Double?, hangCount: Int, longestHangSeconds: Double,
        app: String, os: String
    ) {
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.scrollHitchTimeRatio = scrollHitchTimeRatio
        self.hangCount = hangCount
        self.longestHangSeconds = longestHangSeconds
        self.app = app
        self.os = os
    }
}

/// 記錄檔的一筆。
public enum HitchEntry: Equatable, Sendable {
    case hitch(HitchEvent)
    case scroll(ScrollSummary)
    case metrics(HitchMetricsDigest)
    /// 匯出檔開頭的一筆:匯出時間與目前的系統狀態。
    case meta(HitchSystemState, at: Date)
}

/// 記錄的儲存:`append` 不阻塞呼叫端(真正的實作在背景序列佇列寫檔)。
public protocol HitchLogStoring: Sendable {
    func append(_ entries: [HitchEntry])
    /// 準備好可分享的檔案(開頭加一筆 `meta`);沒有任何記錄時回 nil。
    func exportFile(meta: HitchEntry?) async -> URL?
    func clear() async
}

/// 固定容量的環形緩衝:滿了丟最舊的。
public struct HitchRingBuffer<Element> {
    private var storage: [Element] = []
    public let capacity: Int

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    public var count: Int { storage.count }

    public mutating func append(_ element: Element) {
        storage.append(element)
        if storage.count > capacity { storage.removeFirst(storage.count - capacity) }
    }

    /// 取出全部(依時間順序)並清空。
    public mutating func drain() -> [Element] {
        defer { storage.removeAll(keepingCapacity: true) }
        return storage
    }

    public mutating func removeAll() { storage.removeAll(keepingCapacity: true) }
}

/// 記錄檔的大小上限:丟最舊的整行。
public enum HitchLogTrimmer {
    /// 預設上限約 1 MB。
    public static let defaultMaxBytes = 1_000_000

    /// 超過上限時丟最舊的行,降到上限的八成以下(避免每次寫入都重寫檔案);沒超過原樣回傳。每行算上換行符號。
    public static func trim(_ lines: [String], maxBytes: Int) -> [String] {
        let sizes = lines.map { $0.utf8.count + 1 }
        var total = sizes.reduce(0, +)
        guard total > maxBytes else { return lines }
        let target = Int(Double(maxBytes) * 0.8)
        var dropped = 0
        while total > target, dropped < lines.count {
            total -= sizes[dropped]
            dropped += 1
        }
        return Array(lines.dropFirst(dropped))
    }
}

/// JSON Lines 編碼:每筆一行,含 schema 版本 `v` 與種類 `kind`。
public enum HitchLogEncoder {
    public static let schemaVersion = 1

    public static func line(_ entry: HitchEntry) -> String {
        var object: [String: Any] = ["v": schemaVersion]
        switch entry {
        case .hitch(let event):
            object["kind"] = "hitch"
            object["t"] = time(event.timestamp)
            object["ms"] = event.milliseconds
            object["frames"] = event.frames
            object["dropped"] = event.droppedFrames
            object["scroll"] = event.scroll.rawValue
            object["offsetY"] = event.offsetY
            object["velocityY"] = event.velocityY
            object["cells"] = event.visibleCells
            object["applies"] = event.activity.batchApplies
            object["fits"] = event.activity.fitCount
            object["fitMs"] = round1(event.activity.fitMilliseconds)
            object["offsetFixes"] = event.activity.offsetCorrections
            object["offsetFixPts"] = round1(event.activity.offsetCorrectionPoints)
            object["sizeChanges"] = event.activity.contentSizeChanges
            object["sizePts"] = round1(event.activity.contentSizeChangePoints)
            object["reconfigures"] = event.activity.reconfigures
            object["contentUpdates"] = event.activity.contentUpdates
            object["olderLoading"] = event.olderLoading
            object["working"] = event.agentWorking
            addSystem(event.system, to: &object, full: true)
        case .scroll(let summary):
            object["kind"] = "scroll"
            object["t"] = time(summary.timestamp)
            object["seconds"] = round3(summary.seconds)
            object["frames"] = summary.frames
            object["avgMs"] = summary.averageIntervalMilliseconds
            object["maxMs"] = summary.maxIntervalMilliseconds
            object["hitches"] = summary.hitchEvents
            object["hitchMs"] = summary.hitchMilliseconds
            object["hitchRatio"] = round3(summary.hitchTimeRatio)
            object["working"] = summary.agentWorking
            addSystem(summary.system, to: &object, full: false)
        case .metrics(let digest):
            object["kind"] = "metrics"
            object["t"] = time(digest.periodEnd)
            object["periodStart"] = time(digest.periodStart)
            object["periodEnd"] = time(digest.periodEnd)
            if let ratio = digest.scrollHitchTimeRatio { object["scrollHitchTimeRatio"] = round3(ratio) }
            object["hangs"] = digest.hangCount
            object["longestHangSeconds"] = round1(digest.longestHangSeconds)
            object["app"] = digest.app
            object["os"] = digest.os
        case .meta(let system, let date):
            object["kind"] = "meta"
            object["t"] = time(date)
            addSystem(system, to: &object, full: true)
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func addSystem(_ system: HitchSystemState, to object: inout [String: Any], full: Bool) {
        object["thermal"] = system.thermal
        object["lowPower"] = system.lowPower
        object["device"] = system.device
        object["os"] = system.os
        object["app"] = system.app
        if full {
            object["reduceTransparency"] = system.reduceTransparency
            object["reduceMotion"] = system.reduceMotion
            object["textSize"] = system.textSize
            object["maxFps"] = system.maxFramesPerSecond
        }
    }

    private static func time(_ date: Date) -> String { date.formatted(.iso8601) }
    static func round1(_ value: Double) -> Double { (value * 10).rounded() / 10 }
    static func round3(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
}

/// 設定頁的開關(預設開啟;存在這支裝置)。
public enum HitchLogSettings {
    public static let enabledKey = "diagnostics.hitchLog"

    public static func isEnabled(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }
}
