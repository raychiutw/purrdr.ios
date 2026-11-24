import Foundation
import Synchronization

/// 流量的網路類型。由平台注入(iOS 以網路路徑監看)，核心只收「目前是哪一種」。
public enum TrafficNetwork: String, Sendable, Codable, CaseIterable, Hashable {
    case wifi
    case cellular
    case other
}

extension TrafficNetwork {
    /// 路徑實際走的介面換成計量的類型:Wi-Fi 優先(同時有 Wi-Fi 與行動網路時流量走 Wi-Fi),其次行動網路,其餘(有線、VPN 等)是其他。
    public init(usesWiFi: Bool, usesCellular: Bool) {
        self = usesWiFi ? .wifi : usesCellular ? .cellular : .other
    }
}

public enum TrafficDirection: Sendable, Hashable {
    case sent
    case received
}

/// 一組送出與收到的位元組。
public struct TrafficBytes: Sendable, Codable, Equatable {
    public var sent: Int
    public var received: Int

    public init(sent: Int = 0, received: Int = 0) {
        self.sent = sent
        self.received = received
    }

    public var total: Int { sent + received }

    public static func + (lhs: TrafficBytes, rhs: TrafficBytes) -> TrafficBytes {
        TrafficBytes(sent: lhs.sent + rhs.sent, received: lhs.received + rhs.received)
    }
}

/// 一台主機在各網路類型的用量。
public typealias HostTraffic = [TrafficNetwork: TrafficBytes]

/// 一天(本地時區)的用量:主機 id → 網路類型 → 位元組。
public struct TrafficDay: Sendable, Codable, Equatable {
    /// `yyyy-MM-dd`(本地時區的日曆日)。
    public var day: String
    public var hosts: [String: HostTraffic]

    public init(day: String, hosts: [String: HostTraffic] = [:]) {
        self.day = day
        self.hosts = hosts
    }
}

public typealias TrafficSaveScheduling = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void

/// 主機連線層回報位元組的入口(連線不知道計量長什麼樣子)。
public typealias TrafficRecording = @Sendable (TrafficDirection, Int) -> Void

/// 用量的存放處。每天一筆，只存這支裝置(不同步、不上傳)。
public protocol TrafficStore: Sendable {
    func load() -> [TrafficDay]
    func save(_ days: [TrafficDay])
}

/// 只在記憶體(UI 測試、單元測試)。
public final class InMemoryTrafficStore: TrafficStore {
    private let state = Mutex<(days: [TrafficDay], saves: Int)>(([], 0))

    public init(days: [TrafficDay] = []) { state.withLock { $0.days = days } }

    public func load() -> [TrafficDay] { state.withLock { $0.days } }

    public func save(_ days: [TrafficDay]) {
        state.withLock {
            $0.days = days
            $0.saves += 1
        }
    }

    /// 寫入次數(測試用)。
    public var saveCount: Int { state.withLock { $0.saves } }
}

/// 存成一個 JSON 檔。讀不懂(壞檔)當作沒有資料;寫失敗不影響 app(下次再寫)。
public struct FileTrafficStore: TrafficStore {
    private let url: URL

    public init(url: URL) { self.url = url }

    public func load() -> [TrafficDay] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([TrafficDay].self, from: data)) ?? []
    }

    public func save(_ days: [TrafficDay]) {
        guard let data = try? JSONEncoder().encode(days) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        #if canImport(Darwin)
        // 只屬於這支裝置的用量:不進 iCloud 備份(#353)。原子寫入每次換新檔，所以每次都要標。
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = url
        try? excluded.setResourceValues(values)
        #endif
    }
}

/// 主機連線建好之後才接上計量的轉接點:沒接時不記。SSH 主機通道與 HTTPS 主機連線各持有一個。
public final class TrafficSink: Sendable {
    /// 閉包放在 class 的 `let` 裡:放進 `Mutex<TrafficRecording?>` 再以 `withLock { $0 }` 讀取,
    /// 每次讀取都會在儲存槽的泛型抽象層級與具體型別之間重新包一層 reabstraction thunk 並寫回,
    /// 呼叫鏈與釋放鏈隨記錄次數無限增長,最後在 NIO 執行緒 stack 溢位(#470)。
    private final class Box: Sendable {
        let recording: TrafficRecording
        init(_ recording: @escaping TrafficRecording) { self.recording = recording }
    }

    private let box: Mutex<Box?>

    public init(_ recording: TrafficRecording? = nil) { box = Mutex(Self.box(recording)) }

    public func attach(_ recording: TrafficRecording?) {
        let new = Self.box(recording)
        box.withLock { $0 = new }
    }

    private static func box(_ recording: TrafficRecording?) -> Box? {
        if let recording { return Box(recording) }
        return nil
    }

    public func record(_ direction: TrafficDirection, _ bytes: Int) {
        let current = box.withLock { $0 }
        current?.recording(direction, bytes)
    }
}

/// 流量計量(#353,spec #337):依主機 × 網路類型 × 方向累計，按日存 30 天;「這次開啟」只在記憶體。
///
/// 時鐘與日曆注入(分日用本地時區的午夜)。`record` 可從任何執行緒呼叫，含 NIO(iOS 非主執行緒 stack 只有 512 KB,#470):它只把(時間、網路類型、方向、位元組數)附加到待處理清單,日曆、日期鍵、字典與存檔排程都在背景序列佇列彙總;讀取介面與 `flush()`／`reset()` 先同步彙總尚未處理的部分,語意不變。寫入存放處有節流並合併;`flush()` 一定寫(app 進背景時呼叫)。
public final class TrafficMeter: Sendable {
    /// 保留的天數(含今天)。
    public static let retentionDays = 30
    /// 兩次自動寫入的最短間隔。
    public static let saveInterval: TimeInterval = 5

    private struct State {
        var days: [String: [String: HostTraffic]]
        var launch: [String: HostTraffic] = [:]
        var lastSave: Date?
        var dirty = false
        /// 已排了一次背景存檔、還沒執行(合併用)。
        var savePending = false
    }

    /// `record` 在呼叫端執行緒留下的最小記錄(只有純數值與字串參照)。
    private struct Pending {
        var hostID: String
        var direction: TrafficDirection
        var bytes: Int
        var date: Date
        var network: TrafficNetwork
    }

    private struct PendingQueue {
        var items: [Pending] = []
        /// 已排了一次背景彙總、還沒開始(合併用)。
        var drainScheduled = false
    }

    private let state: Mutex<State>
    private let pending = Mutex(PendingQueue())
    /// 序列化「彙總並排存檔」:讀取介面返回時,先前的 `record` 一定已彙總完、排程已送出。
    private let drainLock = Mutex<Void>(())
    private let networkBox: Mutex<TrafficNetwork>
    /// 彙總開始時呼叫(測試用:確認彙總不在 `record` 的呼叫端執行緒)。
    private let onAggregate: @Sendable () -> Void
    private let store: any TrafficStore
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private let scheduler: TrafficSaveScheduling
    /// 序列化所有 `store.save`(背景排程、`flush()`、`reset()`),不與 `state` 的鎖混用:計量路徑絕不等它。
    private let saveLock = Mutex<Void>(())

    /// 預設的背景存檔:專用序列佇列(不在呼叫 `record` 的 NIO 執行緒上做 I/O,#470)。
    private static let saveQueue = DispatchQueue(label: "purrdr.traffic-save", qos: .utility)
    /// 背景彙總用的專用序列佇列(日期計算、格式化、字典更新都在這裡,#470)。
    private static let aggregateQueue = DispatchQueue(label: "purrdr.traffic-aggregate", qos: .utility)

    public init(
        store: any TrafficStore, now: @escaping @Sendable () -> Date = { Date() }, calendar: Calendar = .current,
        network: TrafficNetwork = .other, scheduler: TrafficSaveScheduling? = nil,
        onAggregate: @escaping @Sendable () -> Void = {}
    ) {
        self.onAggregate = onAggregate
        networkBox = Mutex(network)
        self.store = store
        self.now = now
        self.calendar = calendar
        self.scheduler = scheduler ?? { delay, work in
            if delay <= 0 {
                Self.saveQueue.async(execute: work)
            } else {
                Self.saveQueue.asyncAfter(deadline: .now() + delay, execute: work)
            }
        }
        var loaded: [String: [String: HostTraffic]] = [:]
        for day in store.load() { loaded[day.day] = day.hosts }
        state = Mutex(State(days: loaded))
    }

    /// 平台回報目前的網路類型;之後的位元組記在這一類。
    /// 目前記錄用的網路類型(行動網路上傳大檔前的提醒也看它)。
    public var currentNetwork: TrafficNetwork { networkBox.withLock { $0 } }

    public func setNetwork(_ network: TrafficNetwork) {
        networkBox.withLock { $0 = network }
    }

    /// 某台主機的計量入口,交給它的連線。
    public func recorder(for hostID: String) -> TrafficRecording {
        { [self] direction, bytes in record(hostID: hostID, direction: direction, bytes: bytes) }
    }

    /// 只附加一筆記錄並(必要時)排一次背景彙總:不算日期、不格式化、不碰日曆與字典(#470,呼叫端可能是 NIO 執行緒)。
    public func record(hostID: String, direction: TrafficDirection, bytes: Int) {
        guard bytes > 0 else { return }
        let item = Pending(hostID: hostID, direction: direction, bytes: bytes, date: now(), network: networkBox.withLock { $0 })
        let needsSchedule = pending.withLock { queue -> Bool in
            queue.items.append(item)
            guard !queue.drainScheduled else { return false }
            queue.drainScheduled = true
            return true
        }
        if needsSchedule { Self.aggregateQueue.async { [self] in aggregateAndScheduleSave() } }
    }

    /// 彙總待處理記錄後,必要時排存檔。背景佇列與各讀取介面共用。
    private func aggregateAndScheduleSave() {
        drainLock.withLock { _ in
            if let delay = aggregate() { scheduler(delay) { [self] in performScheduledSave() } }
        }
    }

    /// 把待處理記錄併進按日的字典;回傳需要排程存檔時的延遲(已排過、沒新資料則 `nil`)。
    private func aggregate() -> TimeInterval? {
        onAggregate()
        let items = pending.withLock { queue -> [Pending] in
            queue.drainScheduled = false
            defer { queue.items = [] }
            return queue.items
        }
        guard !items.isEmpty else { return nil }
        return state.withLock { state in
            for item in items {
                let today = dayKey(item.date)
                prune(&state, today: item.date)
                func add(_ traffic: inout [String: HostTraffic]) {
                    var entry = traffic[item.hostID, default: [:]][item.network, default: TrafficBytes()]
                    switch item.direction {
                    case .sent: entry.sent += item.bytes
                    case .received: entry.received += item.bytes
                    }
                    traffic[item.hostID, default: [:]][item.network] = entry
                }
                add(&state.launch)
                add(&state.days[today, default: [:]])
            }
            state.dirty = true
            guard !state.savePending else { return nil }
            state.savePending = true
            guard let last = state.lastSave else { return 0 }
            return max(0, Self.saveInterval - (items.last?.date ?? now()).timeIntervalSince(last))
        }
    }

    /// 保留中的每一天(舊到新)。
    public func days() -> [TrafficDay] {
        aggregateAndScheduleSave()
        return state.withLock { state in
            prune(&state, today: now())
            return Self.snapshot(state)
        }
    }

    /// 今天(本地時區)各主機的用量。
    public func today() -> [String: HostTraffic] {
        aggregateAndScheduleSave()
        let key = dayKey(now())
        return state.withLock { state in
            prune(&state, today: now())
            return state.days[key] ?? [:]
        }
    }

    /// 這次開啟(從 app 啟動算起,只在記憶體)各主機的用量。
    public func sinceLaunch() -> [String: HostTraffic] {
        aggregateAndScheduleSave()
        return state.withLock { $0.launch }
    }

    /// 把還沒寫的用量寫進存放處(同步,呼叫者的執行緒;app 進背景時從主執行緒呼叫)。
    public func flush() {
        _ = aggregate()
        saveLock.withLock { _ in
            let toSave: [TrafficDay]? = state.withLock { state in
                prune(&state, today: now())
                guard state.dirty else { return nil }
                state.dirty = false
                state.lastSave = now()
                return Self.snapshot(state)
            }
            if let toSave { store.save(toSave) }
        }
    }

    /// 同 `flush()`,但在背景佇列寫(app 進背景時用,#498):呼叫端(主執行緒)不等檔案寫入。
    /// 呼叫端要自己用 background task 撐到寫完(`completion` 在寫完後於背景佇列呼叫)。
    public func flushInBackground(completion: @escaping @Sendable () -> Void = {}) {
        scheduler(0) { [self] in
            flush()
            completion()
        }
    }

    /// 重設統計:清掉所有歷史與這次開啟。
    public func reset() {
        _ = aggregate()
        saveLock.withLock { _ in
            state.withLock { state in
                state.days = [:]
                state.launch = [:]
                state.dirty = false
                state.lastSave = now()
            }
            store.save([])
        }
    }

    /// 排程到背景的存檔:取當下最新的狀態寫(中間累加的都合併進來)。
    private func performScheduledSave() {
        _ = aggregate()
        saveLock.withLock { _ in
            let toSave: [TrafficDay]? = state.withLock { state in
                state.savePending = false
                prune(&state, today: now())
                guard state.dirty else { return nil }
                state.dirty = false
                state.lastSave = now()
                return Self.snapshot(state)
            }
            if let toSave { store.save(toSave) }
        }
    }

    // MARK: - 內部

    private static func snapshot(_ state: State) -> [TrafficDay] {
        state.days.keys.sorted().map { TrafficDay(day: $0, hosts: state.days[$0] ?? [:]) }
    }

    private func dayKey(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        func padded(_ value: Int, _ width: Int) -> String {
            let digits = String(max(value, 0))
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        return padded(parts.year ?? 0, 4) + "-" + padded(parts.month ?? 0, 2) + "-" + padded(parts.day ?? 0, 2)
    }

    /// 丟掉保留範圍(今天往前 30 天,含今天)之前的天。
    private func prune(_ state: inout State, today: Date) {
        let start = calendar.startOfDay(for: today)
        guard let oldest = calendar.date(byAdding: .day, value: -(Self.retentionDays - 1), to: start) else { return }
        let cutoff = dayKey(oldest)
        let expired = state.days.keys.filter { $0 < cutoff }
        guard !expired.isEmpty else { return }
        for key in expired { state.days[key] = nil }
        state.dirty = true
    }
}
